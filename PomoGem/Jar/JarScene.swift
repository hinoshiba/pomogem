import Combine
import CoreMotion
@preconcurrency import SpriteKit
import UIKit

struct JarLandingEvent {
    let pebble: PebbleDescriptor
    let impactSpeed: CGFloat
    let position: CGPoint
}

/// The one physical gem accepted by the latest jar tap. Inspection is offered
/// only when that same gem is an aggregate and the finger actually landed on
/// its visible footprint; taps on sparse glass may still bounce the nearest
/// gem without pretending that it was selected.
struct JarAcceptedTapSelection: Equatable, Sendable {
    let pebbleID: UUID
    let inspectableAggregateID: UUID?
}

/// A band of the stage the settled pile must stay below (round 12, D4):
/// its top over `minX...maxX` (scene x) may reach `ceiling` (scene y, up)
/// at most. The pile scale steps down for it, never below `minimumScale`.
struct JarPileClearance: Equatable {
    let minX: CGFloat
    let maxX: CGFloat
    let ceiling: CGFloat
    let minimumScale: CGFloat
    /// An optional band (the core's name plate) is worth a smaller pile
    /// only when `minimumScale` would really clear it: a pile out of its
    /// reach keeps its size, and the band gives way instead (its label
    /// hides). A required band (the core, the HUD) steps as far as it may.
    var isOptional = false

    /// The core's clearance never takes the gems of a young jar below this
    /// scale (a pile the scale cannot keep down meets the core drawn in
    /// front of it instead).
    static let coreMinimumScale: CGFloat = 2.0
    /// Half the Home HUD's value row, about 200 pt across.
    static let hudHalfWidth: CGFloat = 100
    /// A settled top this far over its ceiling still counts as clear
    /// (the profile rounds to 4 pt).
    static let tolerance: CGFloat = 2

    /// The rung the pile at `scale` should step to so a settled top at
    /// `top` over a floor at `floor` comes under `ceiling` (the pile's
    /// height above the floor follows the scale), never below
    /// `minimumScale`; `nil` when the pile already fits or cannot shrink.
    func steppedScale(current scale: CGFloat, top: CGFloat, floor: CGFloat) -> CGFloat? {
        guard top > ceiling + Self.tolerance, scale > minimumScale + 0.0001 else { return nil }
        let ratio = max(0, ceiling - floor) / max(1, top - floor)
        if isOptional, scale * ratio < minimumScale - 0.0001 { return nil }
        // At least one rung, so a stubborn heap still converges.
        let target = min(scale * ratio, scale / JarScalePolicy.rungRatio)
        return max(minimumScale, JarScalePolicy.rung(atOrBelow: target))
    }

    /// The name plate keeps a young jar's gems at most two rungs (8 %)
    /// smaller than the largest scale.
    static let namePlateMinimumScale: CGFloat = JarScalePolicy.maximumScale / (JarScalePolicy.rungRatio * JarScalePolicy.rungRatio)

    /// Whether the pile would still fit at `grown` (the next rungs up).
    func fits(top: CGFloat, floor: CGFloat, current scale: CGFloat, grown: CGFloat) -> Bool {
        guard top > floor else { return true }
        return floor + (top - floor) * grown / max(scale, 0.0001) <= ceiling
    }
}

enum JarCapacityEvent {
    case approachingBake(
        physicalCount: Int,
        occupancyPercent: Int,
        remainingPercent: Int
    )
    case bakeStarted(JarBakeRequest)
    case bakeCompleted(JarBakeRequest)
    case layersCompacted(layerCount: Int, scale: CGFloat)
    case hardLimitReached(physicalCount: Int, queuedDrops: Int)
}

/// The live, touchable bottle. Persistence remains outside SpriteKit and is bridged by
/// the aggregate callbacks, so removal and model insertion can be committed by Home.
@MainActor
final class JarScene: SKScene, SKPhysicsContactDelegate, ObservableObject {
    var onLanding: ((JarLandingEvent) -> Void)?
    var onAggregateRequested: ((JarAggregateRequest) -> Void)?
    /// Compatibility callback for screens that have not yet adopted the new
    /// AggregatePebble model. Only one persistence callback is invoked.
    var onBakeRequested: ((JarBakeRequest) -> Void)?
    var onCapacityEvent: ((JarCapacityEvent) -> Void)?
    var onIdlePauseChanged: ((Bool) -> Void)?

    var soundEnabled: Bool {
        get { soundSynth.isEnabled }
        set { soundSynth.isEnabled = newValue }
    }

    var hapticsEnabled: Bool {
        get { haptics.isEnabled }
        set { haptics.isEnabled = newValue }
    }

    var rareRewardMode: RareRewardMode = .standard {
        didSet {
            guard rareRewardMode != oldValue else { return }
            requestRedraw()
            livePebbles.forEach { $0.setRareRewardMode(rareRewardMode) }
            for index in dropQueue.indices {
                dropQueue[index].needsSpecialAnticipation = shouldShowSpecialAnticipation(
                    for: dropQueue[index].descriptor
                )
            }
            if !rareRewardMode.usesEnhancedPresentation {
                for effectName in ["//ambient.twinkle", "//drop.anticipation.rare"] {
                    worldNode.enumerateChildNodes(withName: effectName) { node, _ in
                        node.removeFromParent()
                    }
                }
            }
        }
    }

    var soundVolume: Float {
        get { soundSynth.masterVolume }
        set { soundSynth.masterVolume = newValue }
    }

    /// Reduces decorative effects while preserving the jar's physical gem
    /// interactions, including drops, taps, shakes, and device tilt.
    var reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled {
        didSet {
            guard reduceMotion != oldValue else { return }
            requestRedraw()
            allPebbleNodes.forEach { $0.setReduceMotion(reduceMotion) }
            if reduceMotion {
                // Aggregation source nodes leave `livePebbles` before their
                // decorative move/fade starts. Complete that transaction once
                // while the resulting gem keeps its normal birth impulse.
                if let activeBakeToken = activeBake?.token {
                    completeActiveBake(token: activeBakeToken)
                }
                updateOpticalTilt(horizontal: 0)
                cameraNode.removeAction(forKey: ActionKey.cameraShake)
                cameraNode.position = cameraRestPosition
                worldNode.enumerateChildNodes(withName: "//ambient.twinkle") { node, _ in
                    node.removeFromParent()
                }
                for effectName in [
                    "//drop.dust",
                    "//drop.spark",
                    "//drop.anticipation",
                    "//drop.anticipation.rare",
                    "//obstacle.fusion"
                ] {
                    worldNode.enumerateChildNodes(withName: effectName) { node, _ in
                        node.removeFromParent()
                    }
                }
            }
        }
    }

    /// 演出の強さ (D17, §7.6): the device-local preference. What the jar
    /// shows is `effects` — Reduce Motion implies 控えめ. A change only
    /// redraws the light; it never wakes the physics.
    var effectsIntensity: JarEffectsIntensity = .standard {
        didSet {
            guard effectsIntensity != oldValue else { return }
            requestRedraw()
            allPebbleNodes.forEach { $0.setEffectsIntensity(effectsIntensity) }
            if !effects.allowsSpontaneousTwinkle {
                worldNode.enumerateChildNodes(withName: "//ambient.twinkle") { node, _ in
                    node.removeFromParent()
                }
            }
        }
    }

    /// What the jar shows: the preference, or 控えめ under Reduce Motion.
    var effects: JarEffectsIntensity {
        .resolved(preference: effectsIntensity, reduceMotion: reduceMotion)
    }

    /// Pro (D21): every crystal's copper tag carries its month ("2026.9")
    /// under the count. Nothing else about a crystal depends on Pro.
    var showsMonthLabels = false {
        didSet {
            renderBaseLayers()
            guard showsMonthLabels != oldValue else { return }
            allPebbleNodes.forEach { $0.setMonthEngraving(showsMonthLabels) }
        }
    }

    private enum DropOrigin {
        case interior
        case sceneTop
    }

    private enum CompletionEntryPhysics {
        // JarPhysicsCategory occupies bits 0...2. The mouth's containment
        // edge accepts ordinary pebbles only, allowing this body to enter.
        static let category: UInt32 = 1 << 3
    }

    private struct QueuedDrop {
        let descriptor: PebbleDescriptor
        let horizontalUnit: CGFloat
        let origin: DropOrigin
        var readyUptime: TimeInterval
        var needsSpecialAnticipation: Bool
    }

    private struct CompletionDropTracking {
        let pebbleID: UUID
        var startY: CGFloat
    }

    private struct ActiveBake {
        let token: UUID
        let request: JarBakeRequest
        let sourceNodes: [PebbleNode]
        let formationPoint: CGPoint
        /// Capture the owner at the transaction boundary. Home may disappear
        /// and clear the public callback while the formation animation is
        /// running; resolving the property again at completion would silently
        /// lose the only persistence request after source nodes are removed.
        let persistenceHandler: (JarBakeRequest) -> Void
    }

    private enum ActionKey {
        static let cameraShake = "jar.cameraShake"
        static let tapCaustic = "jar.tapCaustic"
        static let tapSpecular = "jar.tapSpecular"
        static let reducedMotionHighlight = "jar.reducedMotionHighlight"
        static let pileGlowShape = "jar.pileGlow.shape"
    }

    /// A tap launches one primary gem and lets SpriteKit transfer that motion
    /// through real body-to-body contacts. Keeping the launch bounded here
    /// avoids turning a full jar into an expensive all-body animation.
    private enum TapResponse {
        static let cooldown: TimeInterval = 0.68
        static let aggregateInspectionHitPadding: CGFloat = 8
        static let minimumInfluenceRadius: CGFloat = 64
        static let maximumInfluenceRadius: CGFloat = 104
        static let influenceRadiusFraction: CGFloat = 0.28
        static let minimumLocalStrength: CGFloat = 0.04
        /// The closest physical gem must always own a readable response. This
        /// also makes taps on sparse glass tolerant of small view/scene drift.
        static let minimumPrimaryStrength: CGFloat = 0.78
        static let maximumVerticalVelocity = JarTapLaunchPolicy.maximumVerticalVelocity
        static let maximumHorizontalVelocity = JarTapLaunchPolicy.maximumHorizontalVelocity
        static let maximumAngularVelocity: CGFloat = 5.4
        static let maximumLaunchClearance: CGFloat = 3
        static let launchClearanceRadiusFraction: CGFloat = 0.22
        static let returnDelay = JarTapLaunchPolicy.flightDuration
        static let flightDamping: CGFloat = 0.025
        static let settlingDamping: CGFloat = 0.16
        static let restoreDampingDelay: TimeInterval = 0.30
        // A floor contact can consume the first assigned velocity. Reassert it
        // only long enough to wake the primary body; after that, never overwrite
        // SpriteKit's collision result.
        static let reinforcementFrameCount = 3
        /// Wall-clock timers advance even when a busy main thread presents
        /// fewer physics frames. Keep the upward phase open for enough actual
        /// simulated frames to cover the three-diameter free-flight target.
        static let minimumFlightFrameCount = 20
        static let returnFrameRetryDelay: TimeInterval = 0.05
        static let maximumReturnFrameDeferrals = 20
        static let fullEnergyBodyCount: CGFloat = 18
        static let minimumCrowdEnergyScale: CGFloat = 0.55
        static let causticRadius: CGFloat = 28
    }

    private struct TapKick {
        let velocity: CGVector
        let angularVelocity: CGFloat
    }

    private struct LocalTapImpact {
        let pebble: PebbleNode
        let strength: CGFloat
        let horizontalDirection: CGFloat
    }

    private struct PendingTapKick {
        let sequence: UInt64
        let kicks: [UUID: TapKick]
        var remainingReinforcementFrames: Int
        var remainingFlightFrames: Int
    }

    private struct ActiveTapMotion {
        let sequence: UInt64
        let pebbleID: UUID
    }

    private let soundSynth: SoundSynth
    private let haptics: Haptics
    private let worldNode = SKNode()
    private let jarShadowNode = SKShapeNode()
    private let backGlassNode = SKShapeNode()
    private let mouthDepthNode = SKShapeNode()
    private let glassNode = SKShapeNode()
    private let reducedMotionHighlightNode = SKShapeNode()
    private let rimNode = SKShapeNode()
    private let innerRimNode = SKShapeNode()
    private let tapCausticNode = SKShapeNode()
    /// Glass v2: moving additive highlights (reflection bands, shoulder
    /// light) over the pre-rendered front glass; ±6 pt with tilt.
    private let glassHighlightNode = SKSpriteNode()
    /// Copper neck collar: three pre-rendered tilt states (−1, 0, +1) of
    /// which at most two are visible at once.
    private let collarNode = SKNode()
    private let collarCenterNode = SKSpriteNode()
    private let collarLeftNode = SKSpriteNode()
    private let collarRightNode = SKSpriteNode()
    /// Long-term milestone traces engraved on the collar (0…6), mirrored
    /// from the Home presence state. Presentation only.
    var milestoneTraceCount = 0 {
        didSet {
            let clamped = min(max(milestoneTraceCount, 0), 6)
            if clamped != milestoneTraceCount { milestoneTraceCount = clamped; return }
            if oldValue != milestoneTraceCount { rebuildCollar() }
        }
    }
    /// Warm pool of light on the jar floor; shared halo texture, additive.
    private let floorGlowNode = SKSpriteNode(texture: GemArtwork.poolTexture)
    /// One sprite of light that the whole pile casts into the lower jar
    /// (weighted pile colour mixed 50:50 with #FF9E6B, additive).
    private let pileGlowNode = SKSpriteNode(texture: GemArtwork.poolTexture)
    private var pileGlowBaseAlpha: CGFloat = 0
    /// 「積み上がりの光」 as a gem bed: one baked sprite behind the physics
    /// bodies, set from lifetime grams and the lifetime theme mix only.
    private let gemBedNode = SKSpriteNode()
    /// Lifetime gem bed input. Nothing inside the scene (body count,
    /// fusion, obstacles) writes it; only the SwiftUI owner does.
    var gemBed: JarGemBedState? {
        didSet {
            guard oldValue != gemBed else { return }
            refreshGemBed()
        }
    }
    /// Display scale for baked gem textures: SwiftUI's `displayScale`, set
    /// by the owner (Home) before its first restore and by the jar view on
    /// appear; the SKView's window screen is a fallback. Until one reports
    /// it, textures bake at the 3× ceiling so nothing looks soft.
    var artworkScale: CGFloat = PebbleNode.defaultArtworkScale {
        didSet {
            // Assigning inside didSet does not re-enter it, so the clamped
            // value is stored and compared here in one pass.
            let resolved = GemArtwork.renderScale(artworkScale)
            if resolved != artworkScale { artworkScale = resolved }
            if resolved != GemArtwork.renderScale(oldValue) { refreshGemBed() }
        }
    }
    private var lastPileLightRefresh: TimeInterval = -.greatestFiniteMagnitude
    private var reduceTransparency = UIAccessibility.isReduceTransparencyEnabled
    private let wallNode = SKNode()
    private let floorNode = SKNode()
    private let cameraNode = SKCameraNode()
    private let strataRenderer = StrataRenderer()

    private(set) var visualStrata: [JarStratumVisual] = []
    private(set) var bedrock: JarBedrockVisual?
    private(set) var historyDescriptors: [PebbleDescriptor] = []
    /// Device-local distraction history is supplied independently from every
    /// persisted study projection. Rebuilding study bodies preserves it.
    private(set) var screenTimeObstacleUnitCount = 0
    private(set) var isIdlePaused = false
    /// jar-01 (Docs/GemExperienceDesign.md §7.13): whether SpriteKit's render
    /// loop — the SKView's display link — is stopped. True only while the
    /// physics rests in its idle pause and nothing new waits to be drawn.
    /// The scene drives its SKView's `isPaused` itself: `SpriteView` reads
    /// its `isPaused` argument only when it creates the view (measured:
    /// later changes of the argument never reach the SKView).
    private(set) var isRenderLoopPaused = false
    /// Whether the jar wants device motion at the full rate (§7.13) — its
    /// physics is awake, or a tilt (or the first peak of a shake) keeps it
    /// listening closely for a moment. The motion observer follows it and
    /// drops to its idle rate when it turns false.
    let fullRateMotionDemand = CurrentValueSubject<Bool, Never>(true)
    var wantsFullRateMotion: Bool { fullRateMotionDemand.value }
    /// A light-only redraw of the resting jar keeps the render loop running
    /// this long (several frames at 60 or 30 fps).
    static let redrawHold: TimeInterval = 0.25
    /// A tilt that moved the light keeps full-rate motion and the render
    /// loop this long after its last step, so a slow, deliberate tilt does
    /// not switch rates between steps.
    static let motionWakeHold: TimeInterval = 0.75
    private var redrawUntil: TimeInterval = -.greatestFiniteMagnitude
    private var motionWakeUntil: TimeInterval = -.greatestFiniteMagnitude
    private var isRenderLoopCheckScheduled = false
    private(set) var isBakeInProgress = false
    private(set) var isCapacityReliefActive = false
    private(set) var appliedGravityVector = Constants.Jar.gravityVector
    /// Height profile of the settled pile: the top (scene y, 4 pt steps; 0
    /// when empty) of the resting bodies over each of `pileProfileBinCount`
    /// equal columns of the scene width. Refreshed with the pile light
    /// (every 0.5 s while awake) and when the scene settles; falling or
    /// fast bodies are ignored, so SwiftUI layers outside the scene (the
    /// time core's labels) never follow a drop or a bounce.
    @Published private(set) var settledPileProfile: [CGFloat] = []
    static let pileProfileBinCount = 12
    /// Bodies slower than this (pt/s) count as resting for the profile.
    static let pileProfileRestingSpeed: CGFloat = 24

    /// Highest settled body over the horizontal span `minX...maxX` (scene
    /// coordinates), or 0 when that span is clear.
    func settledPileTop(minX: CGFloat, maxX: CGFloat) -> CGFloat {
        guard !settledPileProfile.isEmpty, size.width > 0,
              minX.isFinite, maxX.isFinite
        else { return 0 }
        let binWidth = size.width / CGFloat(settledPileProfile.count)
        let first = max(0, Int(min(max(minX, 0), size.width) / binWidth))
        let last = min(settledPileProfile.count - 1, Int(min(max(maxX, 0), size.width) / binWidth))
        guard first <= last else { return 0 }
        return settledPileProfile[first ... last].max() ?? 0
    }
    /// Observation-only revision for SwiftUI accessibility. The actual source
    /// of truth remains `livePebbles`; consumers read `physicalPebbleCount`
    /// after this revision invalidates their view.
    @Published private(set) var physicalContentRevision: UInt64 = 0

    private var dropQueue: [QueuedDrop] = []
    private var lastSpawnUptime = -Double.greatestFiniteMagnitude
    private var idleSampleStartedAt: TimeInterval?
    private var lastTwinkleUptime = ProcessInfo.processInfo.systemUptime
    private var lastGemTwinkleUptime: TimeInterval = -.greatestFiniteMagnitude
    private var lastGemTwinkleCheck: TimeInterval = -.greatestFiniteMagnitude
    private var gemTwinkleSequence: UInt64 = 0
    private var eventLightCount = 0
    private var lastTapBounceUptime = -Double.greatestFiniteMagnitude
    private(set) var lastAcceptedTapSelection: JarAcceptedTapSelection?
    private var lastShakeUptime = -Double.greatestFiniteMagnitude
    private var interactionMotionWindow: JarInteractionMotionWindow?
    private var pendingTapKick: PendingTapKick?
    private var activeTapMotion: ActiveTapMotion?
    private var tapPresentationStartPositions: [UUID: CGPoint] = [:]
    private var tapPresentationPrimaryID: UUID?
    private(set) var tapPresentationSequence: UInt64 = 0
    private(set) var tapPresentationMaximumRise: CGFloat = 0
    private(set) var tapPresentationMaximumDisplacement: CGFloat = 0
    private(set) var tapPresentationMovedSecondaryCount = 0
    private var aboveEntryPebbleIDs = Set<UUID>()
    private var completionDropTracking: CompletionDropTracking?
    /// Retain the last presented completion's evidence after a history refresh.
    /// Ordinary additions and restored bodies never advance this sequence.
    private(set) var completionDropSequence: UInt64 = 0
    private(set) var completionDropMaximumFall: CGFloat = 0
    private(set) var completionDropHasLanded = false
    private var lastSecondarySoundUptime = -Double.greatestFiniteMagnitude
    private var lastSecondaryHapticUptime = -Double.greatestFiniteMagnitude
    private var nudgeRateLimiter = JarGestureRateLimiter()
    private var interactionCollisionBudget = JarInteractionCollisionBudget()
    private var mutedLandingIDs = Set<UUID>()
    private var acceptedPebbleIDs = Set<UUID>()
    private var persistedBakedPebbleIDs = Set<UUID>()
    private var persistedStratumIDs = Set<UUID>()
    private var installedHistoryIDs = Set<UUID>()
    private var activeBake: ActiveBake?
    /// A failed save must remain a stable, user-retryable state. Aggregate ids
    /// are deterministic for their ten sources, so suppressing the id prevents
    /// the next frame from recreating the exact failed transaction.
    private var suspendedAggregateIDs = Set<UUID>()
    private var hasReportedHardLimit = false
    private var reduceMotionObserver: NSObjectProtocol?
    private var reduceTransparencyObserver: NSObjectProtocol?
    private var differentiateWithoutColorObserver: NSObjectProtocol?
    private var transientMotionGate = JarTransientMotionGate()
    private var sensorySequence: UInt64 = 0
    private(set) var opticalTiltFraction: CGFloat = 0
    private var lastPublishedPhysicalPebbleCount = 0
    private var lastPublishedHasStudyGems = false
    private var earlyEffortSpotlightIDs = Set<UUID>()
    private var nextStackingIndex = 0

    private var outerJarRect: CGRect {
        Self.outerJarRect(sceneSize: size)
    }

    private var interiorRect: CGRect {
        Self.interiorRect(sceneSize: size)
    }

    /// The bottle in scene coordinates (y up) for a scene of `sceneSize`.
    /// SwiftUI layers behind the scene use the same geometry, so light and
    /// labels line up with the physics walls.
    nonisolated static func outerJarRect(sceneSize size: CGSize) -> CGRect {
        let jarWidth = max(size.width - Constants.Jar.horizontalMargin * 2, 1)
        let jarHeight = min(Constants.Jar.height, max(size.height, 1))
        return CGRect(
            x: (size.width - jarWidth) / 2,
            y: max((size.height - jarHeight) / 2, 0),
            width: jarWidth,
            height: jarHeight
        )
    }

    /// The physics interior (walls and floor) in scene coordinates (y up).
    nonisolated static func interiorRect(sceneSize size: CGSize) -> CGRect {
        let outer = outerJarRect(sceneSize: size)
        return CGRect(
            x: outer.minX + Constants.Jar.wallInset,
            y: outer.minY + Constants.Jar.floorInset,
            width: max(outer.width - Constants.Jar.wallInset * 2, 1),
            height: max(
                outer.height - Constants.Jar.floorInset - Constants.Jar.wallInset,
                1
            )
        )
    }

    /// Top edge of the gem bed measured from the top of a stage of
    /// `stageSize` (SwiftUI, y down), or the floor when there is no bed.
    nonisolated static func gemBedTopFromStageTop(stageSize: CGSize, bed: JarGemBedState?) -> CGFloat {
        let interior = interiorRect(sceneSize: stageSize)
        let bedHeight = bed.map { $0.height(interiorHeight: interior.height) } ?? 0
        return stageSize.height - (interior.minY + bedHeight)
    }

    private var currentFloorY: CGFloat {
        interiorRect.minY
    }

    private var shoulderStartY: CGFloat {
        interiorRect.maxY - min(46, outerJarRect.height * 0.115)
    }

    private var neckBaseY: CGFloat {
        interiorRect.maxY - min(16, outerJarRect.height * 0.04)
    }

    private var neckInset: CGFloat {
        Self.neckInset(jarWidth: outerJarRect.width)
    }

    private var neckInteriorMinX: CGFloat {
        outerJarRect.minX + neckInset + Constants.Jar.wallInset
    }

    private var neckInteriorMaxX: CGFloat {
        outerJarRect.maxX - neckInset - Constants.Jar.wallInset
    }

    var cameraRestPosition: CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    private var livePebbles: [PebbleNode] {
        allPebbleNodes.filter { !$0.isRemovedForBake }
    }

    /// Includes source stones that have crossed the aggregation transaction
    /// boundary and no longer participate in live counts or physics.
    private var allPebbleNodes: [PebbleNode] {
        worldNode.children.compactMap { $0 as? PebbleNode }
    }

    private var bakeEligiblePebbles: [PebbleNode] {
        livePebbles.filter { $0.descriptor.participatesInBake }
    }

    /// Capacity counts the bodies at their own radii: the jar-wide scale
    /// (D4) is presentation only and never moves a fusion threshold.
    private var bakeEligibleRadii: [Double] {
        bakeEligiblePebbles.map { Double($0.localRadius) }
    }

    var physicalPebbleCount: Int { livePebbles.count }
    var screenTimeObstaclePhysicalCount: Int {
        livePebbles.filter { $0.descriptor.isScreenTimeObstacle }.count
    }
    var screenTimeObstacleAccessibilityDescription: String? {
        guard screenTimeObstacleUnitCount > 0 else { return nil }
        return "寄り道の黒い石\(screenTimeObstaclePhysicalCount)個、10分の石\(screenTimeObstacleUnitCount.formatted())個分。勉強の積み上げには含まれません"
    }
    private var studyPhysicalBodyCount: Int {
        livePebbles.filter { !$0.descriptor.isScreenTimeObstacle }.count
    }
    /// The gems device motion is for — study gems (and the tutorial's
    /// stand-in). Black stones or milestone stones alone never keep the
    /// sensor on.
    var hasStudyGems: Bool {
        livePebbles.contains {
            !$0.descriptor.isScreenTimeObstacle && !$0.descriptor.isAchievement
        }
    }
    var physicalAggregateCount: Int { livePebbles.filter { $0.descriptor.isAggregate }.count }
    var representedPebbleCount: Int {
        livePebbles.filter { !$0.descriptor.isScreenTimeObstacle }.reduce(0) {
            $0 + ($1.descriptor.aggregate?.pebbleCount ?? ($1.descriptor.isAchievement ? 0 : 1))
        }
    }
    var queuedDropCount: Int { dropQueue.count }
    var hasCompletionDropInFlight: Bool {
        dropQueue.contains { $0.origin == .sceneTop }
            || livePebbles.contains {
                aboveEntryPebbleIDs.contains($0.descriptor.id) && !$0.hasLanded
            }
    }

    func hasLandedPebble(withID id: UUID) -> Bool {
        livePebbles.contains { $0.descriptor.id == id && $0.hasLanded }
    }

    /// Establishes a quiet baseline when Home loads its device-local ledger.
    /// Calling this with zero is the explicit obstacle-reset operation.
    func setScreenTimeObstacles(totalUnits: Int) {
        updateScreenTimeObstacles(totalUnits: totalUnits, animated: false)
    }

    /// Reconcile only the black stream. Decimal carries replace black roots;
    /// they never request a study fusion or issue a study landing callback.
    func updateScreenTimeObstacles(totalUnits: Int, animated: Bool = true) {
        let previousTotal = screenTimeObstacleUnitCount
        screenTimeObstacleUnitCount = max(0, totalUnits)
        let desired = ScreenTimeObstacleProjection.visibleDescriptors(
            totalUnits: screenTimeObstacleUnitCount
        ).map(PebbleDescriptor.init(screenTimeObstacle:))
        let desiredIDs = Set(desired.map(\.id))
        let oldIDs = Set(allPebbleNodes.filter { $0.descriptor.isScreenTimeObstacle }
            .map { $0.descriptor.id })
            .union(dropQueue.filter { $0.descriptor.isScreenTimeObstacle }.map { $0.descriptor.id })
        let removedIDs = oldIDs.subtracting(desiredIDs)
        let removedBodies = livePebbles.filter { removedIDs.contains($0.descriptor.id) }
        if !removedIDs.isEmpty || previousTotal != screenTimeObstacleUnitCount {
            worldNode.children.first { $0.name == "obstacle.fusion" }?.removeFromParent()
        }
        if !removedIDs.isEmpty {
            // A tap's pending impulse must not keep referencing a root that a
            // decimal carry has replaced underneath the gesture.
            if let activeTapMotion, removedIDs.contains(activeTapMotion.pebbleID) {
                finishActiveTapMotion(forceReturn: false)
            }
            dropQueue.removeAll { removedIDs.contains($0.descriptor.id) }
            allPebbleNodes.filter { removedIDs.contains($0.descriptor.id) }
                .forEach { $0.removeFromParent() }
            acceptedPebbleIDs.subtract(removedIDs)
            mutedLandingIDs.subtract(removedIDs)
            aboveEntryPebbleIDs.subtract(removedIDs)
        }

        if !animated || screenTimeObstacleUnitCount < previousTotal {
            let queuedObstacleIDs = Set(dropQueue.filter { $0.descriptor.isScreenTimeObstacle }
                .map { $0.descriptor.id })
            dropQueue.removeAll { $0.descriptor.isScreenTimeObstacle }
            acceptedPebbleIDs.subtract(queuedObstacleIDs)
            mutedLandingIDs.subtract(queuedObstacleIDs)
        }

        let existingIDs = Set(allPebbleNodes.map { $0.descriptor.id })
            .union(dropQueue.map { $0.descriptor.id })
        let additions = desired.filter { !existingIDs.contains($0.id) }
        let shouldDrop = animated && screenTimeObstacleUnitCount > previousTotal
        if shouldDrop {
            let carriedID = presentScreenTimeObstacleCarry(
                removedBodies: removedBodies,
                additions: additions
            )
            for descriptor in additions where descriptor.id != carriedID {
                enqueue(descriptor, delay: 0, origin: .interior)
            }
        } else {
            bakeBodies(for: additions)
            for (index, descriptor) in additions.enumerated() {
                acceptedPebbleIDs.insert(descriptor.id)
                let node = makePebbleNode(descriptor)
                let diameter = node.radius * 2
                let columns = max(1, Int(interiorRect.width / diameter))
                node.position = CGPoint(
                    x: min(interiorRect.maxX - node.radius,
                        interiorRect.minX + node.radius + CGFloat(index % columns) * diameter),
                    y: min(interiorRect.maxY - node.radius,
                        currentFloorY + node.radius + CGFloat(index / columns) * diameter)
                )
                node.zRotation = deterministicAngle(for: descriptor.id)
                node.markLanded()
                insertPebble(node)
            }
        }
        guard !removedIDs.isEmpty || !additions.isEmpty || previousTotal != screenTimeObstacleUnitCount else { return }
        // Stones placed at once or carried away change the jar's area now;
        // dropped ones rescale the pile when they land.
        reconcileJarScale()
        publishPhysicalContentChangeIfNeeded(force: true)
        resetIdleObservation()
        resumeSimulation()
    }

    /// A decimal carry has a small, black-only formation gesture. The old
    /// shapes are nonphysical copies; the resulting black root is immediately
    /// the sole physics body, so animation can never duplicate credited units.
    private func presentScreenTimeObstacleCarry(
        removedBodies: [PebbleNode],
        additions: [PebbleDescriptor]
    ) -> UUID? {
        guard !reduceMotion,
              removedBodies.count >= 2,
              let destination = additions.first(where: { candidate in
                  guard let target = candidate.screenTimeObstacle else { return false }
                  return !target.isHistoryPile && removedBodies.allSatisfy {
                      ($0.descriptor.screenTimeObstacle?.level ?? target.level) < target.level
                  }
              })
        else { return nil }
        let center = removedBodies.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.position.x, y: $0.y + $1.position.y)
        }
        let point = CGPoint(
            x: center.x / CGFloat(removedBodies.count),
            y: center.y / CGFloat(removedBodies.count)
        )
        let effect = SKNode()
        effect.name = "obstacle.fusion"
        worldNode.addChild(effect)
        for source in removedBodies {
            guard let obstacle = source.descriptor.screenTimeObstacle else { continue }
            let fragment = SKShapeNode()
            let count = ScreenTimeObstacleAppearance.apply(
                to: fragment,
                descriptor: obstacle,
                radius: source.localRadius,
                scale: artworkScale,
                textureJarScale: source.textureJarScale
            )
            count?.setScale(1 / max(source.jarScale, 0.01))
            fragment.setScale(source.xScale)
            fragment.position = source.position
            fragment.zRotation = source.zRotation
            // The view ignores sibling order: the fading fragments take the
            // top stacking slot, so they stay above the resting bodies as
            // the effect container (added last) used to.
            fragment.zPosition = JarZPosition.pebble(stackingIndex: JarZPosition.stackingSlots - 1)
            effect.addChild(fragment)
            fragment.run(.group([
                .move(to: point, duration: 0.28),
                .scale(to: 0.25 * source.xScale, duration: 0.28),
                .fadeOut(withDuration: 0.28)
            ]))
        }
        effect.run(.sequence([.wait(forDuration: 0.3), .removeFromParent()]))
        let node = makePebbleNode(destination)
        let range = allowedHorizontalRange(at: point.y, radius: node.radius)
        node.position = CGPoint(
            x: min(max(point.x, range.lowerBound), range.upperBound),
            y: min(max(point.y + 12, currentFloorY + node.radius + 6), interiorRect.maxY - node.radius)
        )
        node.setScale(0.4 * node.jarScale)
        node.alpha = 0.25
        node.physicsBody?.velocity = CGVector(dx: 0, dy: 32)
        node.run(.scale(to: node.jarScale, duration: 0.28), withKey: PebbleNode.birthActionKey)
        node.run(.fadeIn(withDuration: 0.28))
        acceptedPebbleIDs.insert(destination.id)
        insertPebble(node)
        return destination.id
    }
    /// Observation-only test seam: a tap must actively drive exactly one body.
    /// Other gems move only when SpriteKit resolves a real contact.
    var activeTapDrivenBodyCount: Int { pendingTapKick?.kicks.count ?? 0 }
    var activeTapMotionPebbleID: UUID? { activeTapMotion?.pebbleID }
    var isInteractionMotionActive: Bool { interactionMotionWindow != nil }
    var snapshotRect: CGRect { outerJarRect }

    /// The time core (or the colourless vessel) that Home draws behind this
    /// scene, set by the SwiftUI owner; share snapshots draw it behind the
    /// bottle so the exported jar shows the same centrepiece. Presentation
    /// only.
    var shareCore: JarShareCore?

    /// Whether any live body the capture shows overlaps `rect` (scene
    /// coordinates): a share animation must never draw the core over them.
    /// Bodies `hides` leaves out of the image (Screen Time stones, a
    /// self-reported gem left out of the share) do not count.
    func hasBody(intersecting rect: CGRect, hides: (PebbleDescriptor) -> Bool = { _ in false }) -> Bool {
        livePebbles.contains { pebble in
            guard !hides(pebble.descriptor) else { return false }
            let r = pebble.radius
            return CGRect(x: pebble.position.x - r, y: pebble.position.y - r, width: r * 2, height: r * 2)
                .intersects(rect)
        }
    }

    /// Up to `count` points where a glint may catch light in a share
    /// animation: the upper-left facet of the highest resting study gems
    /// the capture shows (never a Screen Time stone, and never a gem
    /// `hides` leaves out, whose place is a hole in the image), in scene
    /// coordinates.
    func shareGlintAnchors(count: Int = 4, hides: (PebbleDescriptor) -> Bool = { _ in false }) -> [CGPoint] {
        livePebbles
            .filter { !$0.descriptor.isScreenTimeObstacle && !hides($0.descriptor) && $0.hasLanded && $0.position.x.isFinite && $0.position.y.isFinite }
            .sorted { ($0.position.y + $0.radius, $0.descriptor.id.uuidString) > ($1.position.y + $1.radius, $1.descriptor.id.uuidString) }
            .prefix(max(0, count))
            .map { CGPoint(x: $0.position.x - $0.radius * 0.32, y: $0.position.y + $0.radius * 0.42) }
    }

    /// Share of the interior height left free between the highest body and
    /// the mouth (worst-case capacity reviews; presentation only).
    var pileHeadroomFraction: CGFloat {
        let interior = interiorRect
        let top = livePebbles.map { $0.position.y + $0.radius }.max() ?? interior.minY
        return max(0, (interior.maxY - top) / max(interior.height, 1))
    }

    // MARK: Jar-wide scale (D4)

    /// The scale every study body is shown at (`JarScalePolicy`; Screen Time
    /// stones use their own capped share of it). It changes only when a
    /// drop lands, a fusion completes, the jar restores, or its content is
    /// replaced (history sync, rotation, Screen Time); a smaller jar may
    /// shrink it at once, a larger one never grows it by itself.
    private(set) var jarScale: CGFloat = 1
    /// The scale the pile moves to once the incoming drop has landed.
    private var scheduledJarScale: CGFloat?
    /// A landing asked for the scheduled scale; applied on the next update,
    /// outside SpriteKit's contact callback.
    private var appliesScheduledJarScale = false
    /// Every scale change so far (Debug reviews and tests).
    private(set) var jarScaleChangeCount = 0
    /// Bands the settled pile stays below (the time core, the Home HUD),
    /// set by the SwiftUI owner (round 12). Empty keeps the area rule only.
    var pileClearances: [JarPileClearance] = [] {
        didSet {
            guard pileClearances != oldValue else { return }
            // A higher ceiling (the completion card closed, the core moved
            // up) lets the next landing or fusion grow the pile again.
            let rose = pileClearances.count != oldValue.count
                || zip(pileClearances, oldValue).contains { $0.ceiling > $1.ceiling + 8 }
            if rose { pileHeightCap = JarScalePolicy.maximumScale }
            // A resting jar under a lower ceiling (the card shortened it)
            // steps down now; an awake one does when it settles.
            if isIdlePaused { enforcePileClearances() }
        }
    }
    /// The largest scale the settled pile may take under `pileClearances`
    /// (learned when it settles; the area rule still applies below it).
    private(set) var pileHeightCap: CGFloat = JarScalePolicy.maximumScale
    /// True from the moment ten gems start to converge until their crystal
    /// has flashed (about 0.9 s): the core's labels step aside meanwhile.
    @Published private(set) var isFusionSpotlightActive = false
    /// The scene has drawn at least one frame. Before that (a restore or
    /// the first layout of a new Home) scale changes apply at once, so a jar
    /// never visibly resizes while it appears.
    private var hasRenderedFrame = false

    private var interiorArea: CGFloat {
        interiorRect.width * interiorRect.height
    }

    /// Σπr² at the bodies' own radii: the live bodies and `extra` (the
    /// incoming drop or a new crystal). Queued drops count only once they
    /// spawn, so a waiting reward never resizes the pile before it lands.
    private func jarBaseArea(adding extra: [PebbleDescriptor] = []) -> CGFloat {
        JarScalePolicy.baseArea(
            radii: livePebbles.map(\.localRadius) + extra.map(\.radius)
        )
    }

    /// The scale the jar resolves to for its current content (plus `extra`),
    /// with the policy's hysteresis against the scale it shows now.
    private func resolvedJarScale(adding extra: [PebbleDescriptor] = []) -> CGFloat {
        min(
            JarScalePolicy.resolvedScale(
                current: jarScale,
                baseArea: jarBaseArea(adding: extra),
                interiorArea: interiorArea
            ),
            pileHeightCap
        )
    }

    /// Resting gems stack about this much of a restore row's height.
    static let restoreRowNesting: CGFloat = 0.75

    /// Highest resting body over `minX...maxX` (scene coordinates), from
    /// the bodies themselves (landed, not leaving for a fusion).
    private func restingPileTop(minX: CGFloat, maxX: CGFloat) -> CGFloat {
        livePebbles.reduce(CGFloat.zero) { top, pebble in
            guard !pebble.isRemovedForBake, pebble.hasLanded,
                  pebble.position.x.isFinite, pebble.position.y.isFinite
            else { return top }
            let radius = pebble.radius
            guard pebble.position.x + radius >= minX, pebble.position.x - radius <= maxX else { return top }
            return max(top, pebble.position.y + radius)
        }
    }

    /// Round 12 (D4): the area rule sizes the gems, and the settled pile
    /// keeps below the core and the HUD. When the pile rests over one of
    /// `pileClearances`, the whole jar steps down (0.5 s) to the rung whose
    /// pile fits, never below that band's floor, and remembers it as a cap
    /// for later landings; a pile with room for two more rungs lifts the cap
    /// again (it grows at the next landing or fusion, never by itself).
    ///
    /// `fromRestoreRows`: the pile is the restore's rows, not yet settled.
    /// Rows stack a whole diameter each where resting gems nest, so their
    /// height is taken at `restoreRowNesting`, and optional bands wait for
    /// the settled pile (an over-tall estimate never costs the gems size).
    @discardableResult
    private func enforcePileClearances(fromRestoreRows: Bool = false) -> Bool {
        guard !pileClearances.isEmpty, !isBakeInProgress, !livePebbles.isEmpty else { return false }
        let floor = currentFloorY
        var stepped: CGFloat?
        for clearance in pileClearances where !(fromRestoreRows && clearance.isOptional) {
            var top = restingPileTop(minX: clearance.minX, maxX: clearance.maxX)
            if fromRestoreRows, top > floor {
                top = floor + (top - floor) * Self.restoreRowNesting
            }
            if let scale = clearance.steppedScale(current: jarScale, top: top, floor: floor) {
                stepped = min(stepped ?? scale, scale)
            }
        }
        if let stepped, stepped < jarScale - 0.0001 {
            pileHeightCap = stepped
            applyJarScale(stepped, animated: true)
            return true
        }
        guard pileHeightCap < JarScalePolicy.maximumScale - 0.0001 else { return false }
        let grown = min(
            JarScalePolicy.maximumScale,
            jarScale * pow(JarScalePolicy.rungRatio, CGFloat(JarScalePolicy.growthRungs))
        )
        let roomy = pileClearances.allSatisfy { clearance in
            clearance.fits(
                top: restingPileTop(minX: clearance.minX, maxX: clearance.maxX),
                floor: floor,
                current: jarScale,
                grown: grown
            )
        }
        if roomy { pileHeightCap = max(pileHeightCap, grown) }
        return false
    }

    /// Every body of the scene is created here, at its share of the jar
    /// scale (`studyScale`, the current scale by default).
    private func makePebbleNode(_ descriptor: PebbleDescriptor, studyScale: CGFloat? = nil) -> PebbleNode {
        PebbleNode(
            descriptor: descriptor,
            reduceMotion: reduceMotion,
            rareRewardMode: rareRewardMode,
            artworkScale: artworkScale,
            jarScale: JarScalePolicy.bodyScale(for: descriptor, studyScale: studyScale ?? jarScale),
            effectsIntensity: effectsIntensity,
            showsMonthEngraving: showsMonthLabels
        )
    }

    /// Moves every live body to `newScale`. Animated changes last
    /// `JarScalePolicy.transitionDuration` and move the visual and the
    /// physics radius together, a few percent a frame, so the solver
    /// separates growing neighbours gently; the pile is woken for them and
    /// a wall rescue runs when they end. The misses of the new size bake in
    /// one parallel pass: off the main thread for an animated change (the
    /// bodies keep their textures until it is in, round 12), at once for an
    /// instant one (a restore, a jar not yet drawn).
    private func applyJarScale(_ rawScale: CGFloat, animated: Bool) {
        scheduledJarScale = nil
        appliesScheduledJarScale = false
        let newScale = PebbleNode.sanitizedJarScale(rawScale)
        let bodies = livePebbles
        let needsChange = abs(newScale - jarScale) > 0.0001
            || bodies.contains {
                abs($0.jarScaleTarget - JarScalePolicy.bodyScale(for: $0.descriptor, studyScale: newScale)) > 0.0001
            }
        guard needsChange else { return }
        jarScale = newScale
        jarScaleChangeCount += 1
        let duration = animated && view != nil && hasRenderedFrame ? JarScalePolicy.transitionDuration : 0
        let bakesAhead = duration > 0 && Self.bakesScaleTransitionsInBackground
        if bakesAhead {
            let change = jarScaleChangeCount
            GemTextureAtlas.shared.bakeInBackground(bakeRequests(for: bodies.map(\.descriptor))) { [weak self] in
                // A newer change hands its own textures over.
                guard let self, self.jarScaleChangeCount == change else { return }
                self.livePebbles.forEach { $0.adoptJarScaleTexture() }
                if self.isIdlePaused { self.requestRedraw() }
            }
        } else {
            bakeBodies(for: bodies.map(\.descriptor))
        }
        for pebble in bodies {
            pebble.transitionJarScale(
                to: JarScalePolicy.bodyScale(for: pebble.descriptor, studyScale: newScale),
                duration: duration,
                refreshesTexture: !bakesAhead
            )
            pebble.physicsBody?.isResting = false
        }
        removeAction(forKey: "jar.scale.rescue")
        if duration > 0 {
            run(.sequence([
                .wait(forDuration: duration + 0.05),
                .run { [weak self] in self?.rescuePebblesInsideWalls() }
            ]), withKey: "jar.scale.rescue")
        } else {
            rescuePebblesInsideWalls()
        }
        resumeSimulation()
#if DEBUG && targetEnvironment(simulator)
        JarFrameProbe.shared?.note(String(
            format: "jarScale=%.3f bodies=%d A0=%.0f interior=%.0f",
            newScale,
            bodies.count,
            jarBaseArea(),
            interiorArea
        ))
#endif
    }

    /// Re-resolves the scale for the current content (after a history
    /// sync, a rotation to the shelf or a Screen Time change). Never during
    /// a fusion: its sources have left the pile but its crystal has not
    /// arrived yet, and the fusion resolves the scale itself.
    private func reconcileJarScale(animated: Bool = true) {
        guard !isBakeInProgress else { return }
        applyJarScale(resolvedJarScale(), animated: animated)
    }

    init(
        size: CGSize = CGSize(
            width: Constants.Jar.defaultSceneWidth,
            height: Constants.Jar.height
        ),
        soundSynth: SoundSynth? = nil,
        haptics: Haptics? = nil
    ) {
        self.soundSynth = soundSynth ?? .shared
        self.haptics = haptics ?? .shared
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = .clear
        physicsWorld.gravity = Constants.Jar.gravityVector
        appliedGravityVector = Constants.Jar.gravityVector
        physicsWorld.contactDelegate = self
        installSceneGraph()
        observeAccessibilitySettings()
    }

    required init?(coder aDecoder: NSCoder) {
        soundSynth = .shared
        haptics = .shared
        super.init(coder: aDecoder)
        scaleMode = .resizeFill
        backgroundColor = .clear
        physicsWorld.gravity = Constants.Jar.gravityVector
        appliedGravityVector = Constants.Jar.gravityVector
        physicsWorld.contactDelegate = self
        installSceneGraph()
        observeAccessibilitySettings()
    }

    deinit {
        if let reduceMotionObserver {
            NotificationCenter.default.removeObserver(reduceMotionObserver)
        }
        if let reduceTransparencyObserver {
            NotificationCenter.default.removeObserver(reduceTransparencyObserver)
        }
        if let differentiateWithoutColorObserver {
            NotificationCenter.default.removeObserver(differentiateWithoutColorObserver)
        }
    }

    override func didMove(to view: SKView) {
        // One source of truth for the bake scale: the SwiftUI owner sets
        // `displayScale` before its first restore; the window's screen is
        // only a fallback once the view is really on one.
        if let screenScale = view.window?.screen.scale {
            artworkScale = screenScale
        }
        view.preferredFramesPerSecond = Constants.Jar.targetFramesPerSecond
        view.ignoresSiblingOrder = true
        view.allowsTransparency = true
        soundSynth.prepare()
        haptics.prepare()
        rebuildGeometry()
        // A new SKView (Home shown again) presents a resting jar: draw its
        // frame once, then let the render loop stop again (jar-01).
        requestRedraw()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        rebuildGeometry()
        // A smaller jar may shrink the pile at once (its budget is part of
        // the interior); a larger one waits for the next landing or fusion.
        if !isBakeInProgress, !livePebbles.isEmpty {
            let resolved = resolvedJarScale()
            if resolved < jarScale - 0.0001 {
                applyJarScale(resolved, animated: true)
            }
        }
    }

    func configureBase(
        strata: [JarStratumVisual],
        bedrock: JarBedrockVisual?,
        showsMonthLabels: Bool
    ) {
        let previouslyPersistedIDs = persistedBakedPebbleIDs
        visualStrata = JarStratumVisual.normalized(strata)
        persistedBakedPebbleIDs = Set(visualStrata.flatMap(\.sessionIDs))
        persistedStratumIDs = Set(visualStrata.map(\.id))
        acceptedPebbleIDs.subtract(previouslyPersistedIDs)
        acceptedPebbleIDs.formUnion(persistedBakedPebbleIDs)
        dropQueue.removeAll {
            persistedBakedPebbleIDs.contains($0.descriptor.id)
        }
        mutedLandingIDs.subtract(persistedBakedPebbleIDs)
        for pebble in livePebbles
        where persistedBakedPebbleIDs.contains(pebble.descriptor.id) {
            pebble.removeFromParent()
        }
        // Bedrock is intentionally ignored. The legacy row stays in SwiftData,
        // but fixed layers no longer exist in the live jar.
        self.bedrock = nil
        historyDescriptors = visualStrata.map(\.aggregateDescriptor)
        self.showsMonthLabels = showsMonthLabels
        renderBaseLayers()
        rebuildFloor()
        rescuePebblesBelowFloor()
        synchronizeHistoryBodies()
        resumeSimulation()
    }

    /// Installs active root aggregates. Legacy strata may be supplied during
    /// migration; an AggregatePebble with the same id always wins.
    func configureAggregates(
        _ aggregates: [AggregatePebble],
        legacyStrata: [JarStratumVisual] = []
    ) {
        let previouslyPersistedIDs = persistedBakedPebbleIDs
        let roots = AggregatePebblePolicy.visibleRoots(from: aggregates)
        let aggregateDescriptors = roots.map(PebbleDescriptor.init(aggregate:))
        // A migrated legacy stratum can now be a non-root leaf in the compact
        // hierarchy. Suppress it whenever any modern row with the same ID
        // exists, not only when that modern row is one of the visible roots.
        let modernAggregateIDs = Set(aggregates.map(\.id))
        let legacyDescriptors = JarStratumVisual.normalized(legacyStrata)
            .filter { !modernAggregateIDs.contains($0.id) }
            .map(\.aggregateDescriptor)
        visualStrata = legacyStrata
        bedrock = nil
        historyDescriptors = (aggregateDescriptors + legacyDescriptors).sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.createdAt < $1.createdAt
        }
        // Root descriptors intentionally have no flattened membership above
        // level one. Direct leaf rows (plus legacy strata) are sufficient to
        // suppress already-grouped live pebbles without expanding the tree.
        persistedBakedPebbleIDs = AggregatePebblePolicy.directSessionIDs(from: aggregates)
            .union(legacyStrata.flatMap(\.sessionIDs))
        persistedStratumIDs = Set(historyDescriptors.map(\.id))
        suspendedAggregateIDs.subtract(persistedStratumIDs)
        acceptedPebbleIDs.subtract(previouslyPersistedIDs)
        acceptedPebbleIDs.formUnion(persistedBakedPebbleIDs)
        dropQueue.removeAll { persistedBakedPebbleIDs.contains($0.descriptor.id) }
        mutedLandingIDs.subtract(persistedBakedPebbleIDs)
        for pebble in livePebbles
        where persistedBakedPebbleIDs.contains(pebble.descriptor.id) {
            pebble.removeFromParent()
        }
        synchronizeHistoryBodies()
        rebuildFloor()
        resumeSimulation()
    }

    /// Restores bodies without replaying the reward animation. They are shelf-packed and
    /// allowed to settle naturally, avoiding a noisy waterfall at every app launch.
    func restore(pebbles descriptors: [PebbleDescriptor]) {
        interactionMotionWindow = nil
        finishActiveTapMotion(forceReturn: false)
        transientMotionGate.invalidate()
        tapPresentationStartPositions.removeAll()
        tapPresentationPrimaryID = nil
        tapPresentationMaximumRise = 0
        tapPresentationMaximumDisplacement = 0
        tapPresentationMovedSecondaryCount = 0
        aboveEntryPebbleIDs.removeAll()
        completionDropTracking = nil
        cancelActiveBakeForRestore()
        dropQueue.removeAll()
        mutedLandingIDs.removeAll()
        acceptedPebbleIDs.removeAll()
        acceptedPebbleIDs.formUnion(persistedBakedPebbleIDs)
        interactionCollisionBudget.cancel()
        worldNode.children
            .compactMap { $0 as? PebbleNode }
            .forEach { $0.removeFromParent() }
        worldNode.children.first { $0.name == "obstacle.fusion" }?.removeFromParent()

        var cursorX = interiorRect.minX
        var cursorY = currentFloorY
        var rowHeight = CGFloat.zero

        let combinedDescriptors = historyDescriptors + descriptors.filter {
            !persistedBakedPebbleIDs.contains($0.id) && !$0.isScreenTimeObstacle
        } + ScreenTimeObstacleProjection.visibleDescriptors(
            totalUnits: screenTimeObstacleUnitCount
        ).map(PebbleDescriptor.init(screenTimeObstacle:))
        let uniqueDescriptors = combinedDescriptors.filter {
            acceptedPebbleIDs.insert($0.id).inserted
        }
        let studyDescriptors = uniqueDescriptors.filter { !$0.isScreenTimeObstacle }
        let initiallyVisible = Array(studyDescriptors.prefix(Constants.Jar.maxPhysicsBodies))
            + uniqueDescriptors.filter(\.isScreenTimeObstacle)
        // D4: the restored content (overflow drops included) sets the scale
        // before any body exists, so nothing rescales after the layout.
        scheduledJarScale = nil
        appliesScheduledJarScale = false
        let restoredScale = min(
            JarScalePolicy.resolvedScale(
                current: jarScale,
                baseArea: JarScalePolicy.baseArea(radii: uniqueDescriptors.map(\.radius)),
                interiorArea: interiorArea
            ),
            pileHeightCap
        )
        if abs(restoredScale - jarScale) > 0.0001 {
            jarScale = restoredScale
            jarScaleChangeCount += 1
        }
#if DEBUG && targetEnvironment(simulator)
        let restoreStart = CACurrentMediaTime()
        let bakedBefore = GemTextureAtlas.shared.statistics.keptImages
#endif
        bakeBodies(for: initiallyVisible)
        // Rows are centred: with the large gems of a young jar (D4), a
        // first gem rests under the core instead of in a corner.
        var row: [PebbleNode] = []
        func centerRow() {
            let slack = max(0, interiorRect.maxX - cursorX) / 2
            row.forEach { $0.position.x += slack }
            row.removeAll()
        }
        for descriptor in initiallyVisible {
            let node = makePebbleNode(descriptor)
            if cursorX + node.radius * 2 > interiorRect.maxX {
                centerRow()
                cursorX = interiorRect.minX
                cursorY += rowHeight * 2
                rowHeight = .zero
            }
            rowHeight = max(rowHeight, node.radius)
            node.position = CGPoint(
                x: cursorX + node.radius,
                y: min(cursorY + node.radius, interiorRect.maxY - node.radius)
            )
            node.zRotation = CGFloat.random(in: -.pi ... .pi)
            node.markLanded()
            insertPebble(node)
            row.append(node)
            cursorX += node.radius * 2
        }
        centerRow()
#if DEBUG && targetEnvironment(simulator)
        JarFrameProbe.shared?.note(String(
            format: "restore bodies=%d baked=%d ms=%.1f",
            initiallyVisible.count,
            GemTextureAtlas.shared.statistics.keptImages - bakedBefore,
            (CACurrentMediaTime() - restoreStart) * 1_000
        ))
#endif
        let overflow = studyDescriptors.dropFirst(Constants.Jar.maxPhysicsBodies)
        let now = ProcessInfo.processInfo.systemUptime
        for descriptor in overflow {
            mutedLandingIDs.insert(descriptor.id)
            dropQueue.append(
                QueuedDrop(
                    descriptor: descriptor,
                    horizontalUnit: CGFloat.random(in: -1 ... 1),
                    origin: .interior,
                    readyUptime: now,
                    needsSpecialAnticipation: false
                )
            )
        }
        publishPhysicalContentChangeIfNeeded()
        resetIdleObservation()
        // The rows just laid out already tell roughly whether the pile
        // clears the core and the HUD: step down now, before the jar is
        // first drawn (the settled pile corrects it when it rests).
        enforcePileClearances(fromRestoreRows: true)
        resumeSimulation()
    }

    /// Stops automatic retries for a transaction that failed outside SpriteKit.
    /// Its source records can be restored immediately without causing another
    /// formation/save loop on the following update frame.
    func suspendAggregateAfterPersistenceFailure(id: UUID) {
        suspendedAggregateIDs.insert(id)
        hasReportedHardLimit = false
        resetIdleObservation()
    }

    /// Re-enables exactly one user-requested attempt. A second failure suspends
    /// the same deterministic id again, so repeated storage errors never turn
    /// into an automatic animation/save loop.
    @discardableResult
    func retryAggregatePersistence(id: UUID) -> Bool {
        guard suspendedAggregateIDs.remove(id) != nil,
              !isBakeInProgress
        else { return false }
        resumeSimulation()
        let didBegin = beginBakeIfNeeded(force: true)
        if !didBegin {
            // A missing callback or temporarily unsettled source must not turn
            // a failed button press back into automatic retry mode.
            suspendedAggregateIDs.insert(id)
        }
        return didBegin
    }

    private func synchronizeHistoryBodies() {
        let wanted = Dictionary(uniqueKeysWithValues: historyDescriptors.map { ($0.id, $0) })
        let wantedIDs = Set(wanted.keys)
        let removedIDs = installedHistoryIDs.subtracting(wantedIDs)
        if !removedIDs.isEmpty {
            dropQueue.removeAll { removedIDs.contains($0.descriptor.id) }
            acceptedPebbleIDs.subtract(removedIDs)
            livePebbles
                .filter { removedIDs.contains($0.descriptor.id) }
                .forEach { $0.removeFromParent() }
        }

        // A synchronized row may be repaired in place while retaining its
        // stable UUID. Identity alone therefore cannot prove that the SpriteKit
        // snapshot still has the right color, count, mass or radius.
        let replacements: [(PebbleNode, PebbleDescriptor)] = livePebbles.compactMap {
            pebble in
            guard let descriptor = wanted[pebble.descriptor.id],
                  !pebble.descriptor.hasSamePresentation(as: descriptor)
            else { return nil }
            return (pebble, descriptor)
        }
        if !replacements.isEmpty {
            finishActiveTapMotion(forceReturn: false)
            transientMotionGate.invalidate()
            for (pebble, descriptor) in replacements {
                replaceHistoryBody(pebble, with: descriptor)
            }
        }

        for index in dropQueue.indices {
            let queued = dropQueue[index]
            guard let descriptor = wanted[queued.descriptor.id],
                  !queued.descriptor.hasSamePresentation(as: descriptor)
            else { continue }
            dropQueue[index] = QueuedDrop(
                descriptor: descriptor,
                horizontalUnit: queued.horizontalUnit,
                origin: queued.origin,
                readyUptime: queued.readyUptime,
                needsSpecialAnticipation: queued.needsSpecialAnticipation
            )
        }

        let existingIDs = Set(livePebbles.map { $0.descriptor.id })
            .union(dropQueue.map { $0.descriptor.id })
        let additions = historyDescriptors.filter { !existingIDs.contains($0.id) }
        bakeBodies(for: additions)
        for (index, descriptor) in additions.enumerated() {
            guard acceptedPebbleIDs.insert(descriptor.id).inserted else { continue }
            let node = makePebbleNode(descriptor)
            let columns = max(1, Int(interiorRect.width / max(node.radius * 2, 1)))
            let column = index % columns
            let row = index / columns
            node.position = CGPoint(
                x: min(
                    interiorRect.maxX - node.radius,
                    interiorRect.minX + node.radius + CGFloat(column) * node.radius * 2
                ),
                y: min(
                    interiorRect.maxY - node.radius,
                    currentFloorY + node.radius + CGFloat(row) * node.radius * 2
                )
            )
            node.zRotation = deterministicAngle(for: descriptor.id)
            node.markLanded()
            insertPebble(node)
        }
        installedHistoryIDs = wantedIDs
        if !removedIDs.isEmpty || !replacements.isEmpty || !additions.isEmpty {
            reconcileJarScale()
        }
        publishPhysicalContentChangeIfNeeded(force: !replacements.isEmpty)
        resetIdleObservation()
    }

    private func replaceHistoryBody(
        _ oldNode: PebbleNode,
        with descriptor: PebbleDescriptor
    ) {
        let oldBody = oldNode.physicsBody
        let oldPosition = oldNode.position
        let oldRotation = oldNode.zRotation
        let wasLanded = oldNode.hasLanded

        let node = makePebbleNode(descriptor)
        let minimumY = currentFloorY + node.radius
        let maximumY = interiorRect.maxY - node.radius
        let safeY = minimumY <= maximumY
            ? min(max(oldPosition.y, minimumY), maximumY)
            : interiorRect.midY
        let horizontalRange = allowedHorizontalRange(
            at: safeY,
            radius: node.radius
        )
        node.position = CGPoint(
            x: min(
                max(oldPosition.x, horizontalRange.lowerBound),
                horizontalRange.upperBound
            ),
            y: safeY
        )
        node.zRotation = oldRotation
        if wasLanded {
            node.markLanded()
        }

        oldNode.removeFromParent()
        insertPebble(node)
        if let oldBody, let body = node.physicsBody {
            body.velocity = oldBody.velocity
            body.angularVelocity = oldBody.angularVelocity
            body.linearDamping = oldBody.linearDamping
            body.angularDamping = oldBody.angularDamping
            body.usesPreciseCollisionDetection = oldBody.usesPreciseCollisionDetection
            body.isDynamic = oldBody.isDynamic
            body.isResting = oldBody.isResting
        }
        node.rememberObservedPosition()
        node.updatePresentationLighting(horizontal: opticalTiltFraction)
    }

    /// Adds a body on top of the bodies already in the jar. The view ignores
    /// sibling order (so SpriteKit can batch), which leaves ties at equal z
    /// unordered; each body therefore gets its own tiny stacking offset in
    /// insertion order — the order the node tree used to give — kept inside
    /// every layer's band (`JarZPosition.stackingSpan`).
    private func insertPebble(_ node: PebbleNode) {
        if nextStackingIndex >= JarZPosition.stackingSlots {
            // Renumber the live bodies compactly, keeping their order.
            let ordered = allPebbleNodes.sorted { $0.zPosition < $1.zPosition }
            for (index, pebble) in ordered.enumerated() {
                pebble.zPosition = JarZPosition.pebble(stackingIndex: index)
            }
            nextStackingIndex = ordered.count
        }
        node.zPosition = JarZPosition.pebble(stackingIndex: nextStackingIndex)
        nextStackingIndex += 1
        worldNode.addChild(node)
    }

    /// Bakes the bodies about to be created in one parallel pass (misses
    /// only), so a restore never bakes a full jar one body at a time on the
    /// main thread (§7.13).
    private func bakeBodies(for descriptors: [PebbleDescriptor]) {
#if DEBUG && targetEnvironment(simulator)
        guard !JarFrameProbe.disablesPrebake else { return }
#endif
        GemTextureAtlas.shared.bakeMissing(bakeRequests(for: descriptors))
    }

    /// The body bakes `descriptors` need at the current jar scale.
    private func bakeRequests(for descriptors: [PebbleDescriptor]) -> [GemTextureAtlas.BakeRequest] {
        let scale = artworkScale
        let studyScale = jarScale
        return descriptors.compactMap {
            PebbleNode.bakeRequest(
                for: $0,
                scale: scale,
                jarScale: JarScalePolicy.bodyScale(for: $0, studyScale: studyScale)
            )
        }
    }

    /// Whether an animated scale change bakes its new rung off the main
    /// thread (the Debug frame probe can measure the former synchronous
    /// bake by turning the pre-bake off).
    private static var bakesScaleTransitionsInBackground: Bool {
#if DEBUG && targetEnvironment(simulator)
        !JarFrameProbe.disablesPrebake
#else
        true
#endif
    }

    private func deterministicAngle(for id: UUID) -> CGFloat {
        let value = id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return (CGFloat(abs(value % 10_000)) / 10_000 * 2 - 1) * .pi
    }

    /// Immediately queues a manual/restored reward drop. Multiple calls retain 180 ms spacing.
    func drop(_ descriptor: PebbleDescriptor) {
        enqueue(descriptor, delay: .zero)
    }

    func drop(_ descriptors: [PebbleDescriptor]) {
        for descriptor in descriptors {
            enqueue(descriptor, delay: .zero)
        }
    }

    /// Home releases this presentation after the completion card has closed
    /// and the jar is visible. Its lower half enters at the scene's top edge,
    /// then falls through the center of the neck without resizing the bottle.
    func dropFromAbove(_ descriptor: PebbleDescriptor) {
        enqueue(descriptor, delay: .zero, origin: .sceneTop)
    }

    /// Removes items that rotate from the live jar into the permanent record
    /// shelf. Their persistence is untouched, and clearing the accepted IDs
    /// allows an older stone to reappear if a newer synced record is removed.
    func removePebbles(withIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        dropQueue.removeAll { ids.contains($0.descriptor.id) }
        mutedLandingIDs.subtract(ids)
        acceptedPebbleIDs.subtract(ids)
        aboveEntryPebbleIDs.subtract(ids)
        if let tracking = completionDropTracking, ids.contains(tracking.pebbleID) {
            completionDropTracking = nil
        }
        for pebble in livePebbles where ids.contains(pebble.descriptor.id) {
            pebble.removeFromParent()
        }
        reconcileJarScale()
        publishPhysicalContentChangeIfNeeded()
        resetIdleObservation()
        resumeSimulation()
    }

    /// Ends transient interaction work when the jar surface is no longer active.
    /// Delayed tap callbacks cannot resume an old interaction on return.
    func cancelInteractionPresentation() {
        finishActiveTapMotion(forceReturn: false)
        transientMotionGate.invalidate()
        interactionCollisionBudget.cancel()
        interactionMotionWindow = nil
    }

    /// Starts the complete reward beat: chime now, then the visual drop at t=350 ms.
    func performCompletionDrop(_ descriptor: PebbleDescriptor) {
        if enqueue(descriptor, delay: Constants.Jar.dropSpawnDelay) {
            soundSynth.playCompletionChime()
        }
    }

    func performCompletionDrop(_ descriptors: [PebbleDescriptor]) {
        var acceptedAny = false
        for descriptor in descriptors {
            if enqueue(
                descriptor,
                delay: Constants.Jar.dropSpawnDelay
            ) {
                acceptedAny = true
            }
        }
        if acceptedAny {
            soundSynth.playCompletionChime()
        }
    }

    /// Directional VoiceOver fallback for an interaction that is normally
    /// driven by physical tilt. It remains deterministic and never randomizes
    /// the vertical component.
    func nudge(
        horizontal direction: CGFloat,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard direction.isFinite else { return }
        let safeDirection = min(max(direction, -1), 1)
        let pebbles = livePebbles
        guard abs(safeDirection) > 0.01,
              !pebbles.isEmpty,
              nudgeRateLimiter.accepts(
                uptime: uptime,
                cooldown: Constants.Jar.nudgeCooldown
              )
        else { return }
        beginInteractionMotionWindow(uptime: uptime)
        for pebble in pebbles {
            // SpriteKit's mass grows with the jar scale; the impulse grows
            // with it, so a nudge moves every jar the same.
            let massScale = pebble.xScale * pebble.xScale
            pebble.physicsBody?.applyImpulse(CGVector(
                dx: safeDirection * Constants.Jar.shakeHorizontalImpulse * massScale,
                dy: Constants.Jar.shakeVerticalImpulseMin * 0.25 * massScale
            ))
        }
        playSensoryFeedback(
            trigger: .tap,
            samples: pebbles.map {
                JarSensorySample(radius: Double($0.sensoryRadius), coupling: 0.45)
            },
            strength: 0.55,
            userInitiated: true
        )
    }

    /// Turns one deliberate, rate-limited device shake into a bounded impulse
    /// across the live stones. Equal impulses let SpriteKit's radius-derived
    /// body mass make large aggregates visibly lag behind smaller gems.
    @discardableResult
    func shakePebbles(strength proposedStrength: CGFloat, horizontal direction: CGFloat) -> Bool {
        guard proposedStrength.isFinite, direction.isFinite else { return false }
        let strength = min(max(proposedStrength, 0), 1)
        let pebbles = livePebbles
        guard strength > 0, !isBakeInProgress, !pebbles.isEmpty else { return false }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastShakeUptime >= Constants.Jar.deviceShakeCooldown else { return false }
        lastShakeUptime = now

        let centroid = CGPoint(
            x: pebbles.reduce(CGFloat.zero) { $0 + $1.position.x }
                / CGFloat(pebbles.count),
            y: pebbles.reduce(CGFloat.zero) { $0 + $1.position.y }
                / CGFloat(pebbles.count)
        )
        beginInteractionMotionWindow(uptime: now)
        finishActiveTapMotion(forceReturn: false)
        transientMotionGate.invalidate()
        let crowdScale = min(
            1,
            max(
                TapResponse.minimumCrowdEnergyScale,
                sqrt(TapResponse.fullEnergyBodyCount / CGFloat(pebbles.count))
            )
        )
        let safeDirection = min(max(direction, -1), 1)
        let horizontalImpulse = Constants.Jar.shakeHorizontalImpulse
            * (0.78 + strength * 0.72) * crowdScale
        let verticalImpulse = (
            Constants.Jar.shakeVerticalImpulseMin
                + (Constants.Jar.shakeVerticalImpulseMax
                    - Constants.Jar.shakeVerticalImpulseMin) * strength
        ) * crowdScale
        for (index, pebble) in pebbles.enumerated() {
            guard let body = pebble.physicsBody else { continue }
            let variation = deterministicVariation(
                for: pebble.descriptor.id,
                salt: index &+ 97
            )
            let fallbackDirection: CGFloat = variation >= 0 ? 1 : -1
            let primaryDirection = abs(safeDirection) >= 0.12
                ? safeDirection
                : fallbackDirection
            let localDirection = min(
                max(primaryDirection * 0.86 + variation * 0.24, -1),
                1
            )
            body.isResting = false
            body.linearDamping = Constants.Jar.linearDamping
            body.usesPreciseCollisionDetection = !pebble.hasLanded
            body.velocity = JarShakeVelocityPolicy.velocity(
                current: body.velocity,
                impulse: CGVector(
                    dx: localDirection * horizontalImpulse,
                    dy: verticalImpulse * (0.86 + abs(variation) * 0.14)
                ),
                // The unscaled mass: a jar of large young gems shakes like
                // the shipping jar (D4 is presentation only).
                mass: pebble.presentationMass
            )
        }
        playTapCaustic(at: centroid, expands: !reduceMotion)
        playSensoryFeedback(
            trigger: .shake,
            samples: pebbles.map {
                JarSensorySample(radius: Double($0.sensoryRadius), coupling: 1)
            },
            strength: Double(strength),
            userInitiated: true
        )
        return true
    }

    /// Launches the nearest gem and lets its contacts send a physical ripple
    /// through the rest of the pile.
    ///
    /// This is deliberately a presentation-only interaction: it does not add,
    /// remove, land, aggregate, or otherwise mutate the study records represented
    /// by the bodies. The return value makes the cooldown behavior testable and
    /// lets accessibility callers use the exact same path as a touch.
    @discardableResult
    func bouncePebbles(at proposedPoint: CGPoint? = nil) -> Bool {
        lastAcceptedTapSelection = nil
        let now = ProcessInfo.processInfo.systemUptime
        let pebbles = livePebbles
        guard !isBakeInProgress, !pebbles.isEmpty else { return false }

        // VoiceOver and keyboard activation do not provide a touch point. Use
        // the visible pile's centroid so those paths still get the same local
        // response instead of shaking every body in the bottle.
        let centroid = CGPoint(
            x: pebbles.reduce(CGFloat.zero) { $0 + $1.position.x }
                / CGFloat(pebbles.count),
            y: pebbles.reduce(CGFloat.zero) { $0 + $1.position.y }
                / CGFloat(pebbles.count)
        )
        let origin = proposedPoint ?? centroid
        guard makeJarPath(in: outerJarRect).contains(origin) else { return false }

        let influenceRadius = min(
            TapResponse.maximumInfluenceRadius,
            max(
                TapResponse.minimumInfluenceRadius,
                interiorRect.width * TapResponse.influenceRadiusFraction
            )
        )
        let physicalPebbles = pebbles.filter { $0.physicsBody != nil }
        guard let primaryPebble = physicalPebbles.min(by: { lhs, rhs in
            let lhsDistance = hypot(
                lhs.position.x - origin.x,
                lhs.position.y - origin.y
            ) - lhs.radius
            let rhsDistance = hypot(
                rhs.position.x - origin.x,
                rhs.position.y - origin.y
            ) - rhs.radius
            if abs(lhsDistance - rhsDistance) > 0.001 {
                return lhsDistance < rhsDistance
            }
            return lhs.descriptor.id.uuidString < rhs.descriptor.id.uuidString
        }) else { return false }

        var impacts: [LocalTapImpact] = physicalPebbles.compactMap { pebble in
            guard pebble.physicsBody != nil else { return nil }
            let dx = pebble.position.x - origin.x
            let dy = pebble.position.y - origin.y
            let centerDistance = hypot(dx, dy)
            let surfaceDistance = max(0, centerDistance - pebble.radius)
            let normalizedDistance = min(surfaceDistance / influenceRadius, 1)
            let remaining = 1 - normalizedDistance
            let strength = remaining * remaining
            guard strength >= TapResponse.minimumLocalStrength else { return nil }
            return LocalTapImpact(
                pebble: pebble,
                strength: strength,
                horizontalDirection: centerDistance > 0.001 ? dx / centerDistance : 0
            )
        }

        // The bottle is presented as one interactive object. A tap inside it
        // must therefore never acknowledge success while leaving every gem
        // still. Promote the nearest physical gem to a readable minimum even
        // when the tap landed on sparse glass or a non-physical backdrop.
        let primaryDX = primaryPebble.position.x - origin.x
        let primaryDY = primaryPebble.position.y - origin.y
        let primaryDistance = hypot(primaryDX, primaryDY)
        let primaryDirection = primaryDistance > 0.001 ? primaryDX / primaryDistance : 0
        if let primaryIndex = impacts.firstIndex(where: {
            $0.pebble.descriptor.id == primaryPebble.descriptor.id
        }) {
            let current = impacts[primaryIndex]
            impacts[primaryIndex] = LocalTapImpact(
                pebble: current.pebble,
                strength: max(current.strength, TapResponse.minimumPrimaryStrength),
                horizontalDirection: current.horizontalDirection
            )
        } else {
            impacts.append(LocalTapImpact(
                pebble: primaryPebble,
                strength: TapResponse.minimumPrimaryStrength,
                horizontalDirection: primaryDirection
            ))
        }

        guard now - lastTapBounceUptime >= TapResponse.cooldown else { return false }
        lastTapBounceUptime = now

        let directHitDistance = hypot(
            primaryPebble.position.x - origin.x,
            primaryPebble.position.y - origin.y
        )
        let inspectableAggregateID = proposedPoint != nil
            && primaryPebble.descriptor.isAggregate
            && directHitDistance
                <= primaryPebble.radius + TapResponse.aggregateInspectionHitPadding
            ? primaryPebble.descriptor.id
            : nil
        lastAcceptedTapSelection = JarAcceptedTapSelection(
            pebbleID: primaryPebble.descriptor.id,
            inspectableAggregateID: inspectableAggregateID
        )

        let horizontalDirection = tapLaunchHorizontalDirection(
            for: primaryPebble,
            origin: origin,
            pileCentroid: centroid
        )

        beginInteractionMotionWindow(uptime: now)
        finishActiveTapMotion(forceReturn: true)
        beginTapPresentationTracking(primary: primaryPebble)
        let activeTapSequence = transientMotionGate.begin()
        guard let primaryImpact = impacts.first(where: {
            $0.pebble.descriptor.id == primaryPebble.descriptor.id
        }), let primaryBody = primaryPebble.physicsBody else {
            transientMotionGate.invalidate()
            return false
        }

        let upwardRoom = max(
            0,
            interiorRect.maxY - primaryPebble.radius - primaryPebble.position.y
        )
        let launchPlan = JarTapLaunchPolicy.plan(
            radius: primaryPebble.radius,
            strength: primaryImpact.strength,
            upwardRoom: upwardRoom
        )
        let spinVariation = deterministicVariation(
            for: primaryPebble.descriptor.id,
            salt: 1
        )
        let desiredVelocity = CGVector(
            dx: min(
                TapResponse.maximumHorizontalVelocity,
                max(
                    -TapResponse.maximumHorizontalVelocity,
                    launchPlan.horizontalVelocity * horizontalDirection
                )
            ),
            dy: min(
                TapResponse.maximumVerticalVelocity,
                launchPlan.verticalVelocity
            )
        )
        let desiredAngularVelocity = min(
            TapResponse.maximumAngularVelocity,
            max(
                -TapResponse.maximumAngularVelocity,
                spinVariation * TapResponse.maximumAngularVelocity
            )
        )

        // Only the selected gem receives a launch. Neighbours keep their own
        // velocities and are woken naturally by SpriteKit contacts, producing
        // the visible chain reaction instead of a synchronized scripted wave.
        let launchClearance = min(
            upwardRoom,
            TapResponse.maximumLaunchClearance,
            primaryPebble.radius * TapResponse.launchClearanceRadiusFraction
        )
        primaryPebble.position.y += launchClearance
        primaryBody.isDynamic = true
        primaryBody.isResting = false
        primaryBody.linearDamping = TapResponse.flightDamping
        primaryBody.usesPreciseCollisionDetection = true
        primaryBody.velocity = desiredVelocity
        primaryBody.angularVelocity = desiredAngularVelocity
        activeTapMotion = ActiveTapMotion(
            sequence: activeTapSequence,
            pebbleID: primaryPebble.descriptor.id
        )

        let tapKicks = [
            primaryPebble.descriptor.id: TapKick(
                velocity: desiredVelocity,
                angularVelocity: desiredAngularVelocity
            )
        ]

        // The jar's intentionally gentle gravity would otherwise let the gem
        // float. Start a decisive return after the readable launch window; any
        // collisions before then remain entirely owned by SpriteKit.
        scheduleTapReturn(
            for: primaryPebble,
            sequence: activeTapSequence,
            returnSpeed: launchPlan.returnVelocity,
            delay: TapResponse.returnDelay,
            remainingFrameDeferrals: TapResponse.maximumReturnFrameDeferrals
        )

        pendingTapKick = PendingTapKick(
            sequence: activeTapSequence,
            kicks: tapKicks,
            remainingReinforcementFrames: TapResponse.reinforcementFrameCount,
            remainingFlightFrames: TapResponse.minimumFlightFrameCount
        )
        playTapCaustic(at: origin, expands: !reduceMotion)
        playSensoryFeedback(
            trigger: .tap,
            samples: impacts.map {
                JarSensorySample(
                    radius: Double($0.pebble.sensoryRadius),
                    coupling: Double($0.strength)
                )
            },
            strength: 0.86,
            userInitiated: true
        )
        return true
    }

    /// Ends the temporary low-damping/CCD state synchronously. Delayed return
    /// callbacks are generation-fenced, so every path that supersedes a tap
    /// must normalize its body before changing that generation.
    private func finishActiveTapMotion(
        expectedSequence: UInt64? = nil,
        forceReturn: Bool
    ) {
        guard let activeTapMotion else {
            if expectedSequence == nil { pendingTapKick = nil }
            return
        }
        if let expectedSequence,
           expectedSequence != activeTapMotion.sequence {
            return
        }

        if let pebble = livePebbles.first(where: {
            $0.descriptor.id == activeTapMotion.pebbleID
        }), let body = pebble.physicsBody {
            body.linearDamping = Constants.Jar.linearDamping
            body.usesPreciseCollisionDetection = !pebble.hasLanded
            if forceReturn {
                let returnSpeed = min(
                    TapResponse.maximumVerticalVelocity,
                    max(abs(body.velocity.dy), 130)
                )
                if body.velocity.dy > -returnSpeed {
                    body.velocity.dy = -returnSpeed
                }
                body.isResting = false
            }
        }
        if pendingTapKick?.sequence == activeTapMotion.sequence {
            pendingTapKick = nil
        }
        self.activeTapMotion = nil
    }

    private func beginTapPresentationTracking(primary: PebbleNode) {
        tapPresentationSequence &+= 1
        tapPresentationPrimaryID = primary.descriptor.id
        tapPresentationMaximumRise = 0
        tapPresentationMaximumDisplacement = 0
        tapPresentationMovedSecondaryCount = 0
        tapPresentationStartPositions = Dictionary(
            uniqueKeysWithValues: livePebbles.map {
                ($0.descriptor.id, $0.position)
            }
        )
    }

    /// Capture physics-frame positions inside SpriteKit itself. A SwiftUI task
    /// can sample too late when a high-velocity gem already crossed much of its
    /// arc, which made the UI regression test under-report visible travel.
    private func updateTapPresentationTrackingIfNeeded() {
        guard pendingTapKick != nil,
              let primaryID = tapPresentationPrimaryID,
              let primaryStart = tapPresentationStartPositions[primaryID]
        else { return }

        var movedSecondaryCount = 0
        for pebble in livePebbles {
            guard let start = tapPresentationStartPositions[pebble.descriptor.id]
            else { continue }
            if pebble.descriptor.id == primaryID {
                tapPresentationMaximumRise = max(
                    tapPresentationMaximumRise,
                    pebble.position.y - primaryStart.y
                )
                tapPresentationMaximumDisplacement = max(
                    tapPresentationMaximumDisplacement,
                    hypot(
                        pebble.position.x - primaryStart.x,
                        pebble.position.y - primaryStart.y
                    )
                )
            } else if hypot(
                pebble.position.x - start.x,
                pebble.position.y - start.y
            ) >= 1.5 {
                movedSecondaryCount += 1
            }
        }
        tapPresentationMovedSecondaryCount = max(
            tapPresentationMovedSecondaryCount,
            movedSecondaryCount
        )
    }

    /// Aim through the pile when possible so the primary body meets another
    /// gem instead of travelling into empty glass. An edge tap still pushes
    /// away from the finger, and available wall room always wins as a safety
    /// fallback.
    private func tapLaunchHorizontalDirection(
        for pebble: PebbleNode,
        origin: CGPoint,
        pileCentroid: CGPoint
    ) -> CGFloat {
        let touchOffset = pebble.position.x - origin.x
        let pileOffset = pileCentroid.x - pebble.position.x
        let meaningfulOffset = max(pebble.radius * 0.18, 2)
        var direction: CGFloat
        if abs(touchOffset) >= meaningfulOffset {
            direction = touchOffset >= 0 ? 1 : -1
        } else if abs(pileOffset) >= meaningfulOffset {
            direction = pileOffset >= 0 ? 1 : -1
        } else {
            direction = deterministicVariation(
                for: pebble.descriptor.id,
                salt: 0
            ) >= 0 ? 1 : -1
        }

        let horizontalRange = allowedHorizontalRange(
            at: pebble.position.y,
            radius: pebble.radius
        )
        let leftRoom = max(0, pebble.position.x - horizontalRange.lowerBound)
        let rightRoom = max(0, horizontalRange.upperBound - pebble.position.x)
        let preferredRoom = direction > 0 ? rightRoom : leftRoom
        let oppositeRoom = direction > 0 ? leftRoom : rightRoom
        if preferredRoom < min(pebble.radius * 2, oppositeRoom * 0.45) {
            direction *= -1
        }
        return direction
    }

    /// Starts the downward half only after SpriteKit has presented the compact
    /// upward kick. This uses the pending simulated-frame budget as the source
    /// of truth, so a temporarily busy main thread cannot collapse the visible
    /// hop while wall-clock timers continue advancing.
    private func scheduleTapReturn(
        for pebble: PebbleNode,
        sequence: UInt64,
        returnSpeed: CGFloat,
        delay: TimeInterval,
        remainingFrameDeferrals: Int
    ) {
        let pebbleID = pebble.descriptor.id
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            [weak self, weak pebble] in
            guard let self,
                  self.transientMotionGate.accepts(sequence),
                  let pebble,
                  pebble.parent != nil,
                  !pebble.isRemovedForBake,
                  let body = pebble.physicsBody
            else { return }

            if remainingFrameDeferrals > 0,
               let pendingTapKick = self.pendingTapKick,
               pendingTapKick.sequence == sequence,
               pendingTapKick.remainingFlightFrames > 0,
               pendingTapKick.kicks[pebbleID] != nil {
                self.scheduleTapReturn(
                    for: pebble,
                    sequence: sequence,
                    returnSpeed: returnSpeed,
                    delay: TapResponse.returnFrameRetryDelay,
                    remainingFrameDeferrals: remainingFrameDeferrals - 1
                )
                return
            }

            if self.pendingTapKick?.sequence == sequence {
                self.pendingTapKick = nil
            }
            let desiredReturnVelocity = -returnSpeed
            if body.velocity.dy > desiredReturnVelocity {
                body.isResting = false
                body.linearDamping = TapResponse.settlingDamping
                body.velocity.dy = desiredReturnVelocity
            }

            DispatchQueue.main.asyncAfter(
                deadline: .now() + TapResponse.restoreDampingDelay
            ) { [weak self] in
                guard let self,
                      self.transientMotionGate.accepts(sequence)
                else { return }
                self.finishActiveTapMotion(
                    expectedSequence: sequence,
                    forceReturn: false
                )
            }
        }
    }

    private func deterministicVariation(for id: UUID, salt: Int) -> CGFloat {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in id.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        hash ^= transientMotionGate.generation &* 0x9E37_79B9_7F4A_7C15
        hash ^= UInt64(truncatingIfNeeded: salt) &* 0xBF58_476D_1CE4_E5B9
        return CGFloat(hash % 2_001) / 1_000 - 1
    }

    private func playTapCaustic(at point: CGPoint, expands: Bool) {
        let safePoint = CGPoint(
            x: min(
                max(point.x, interiorRect.minX + TapResponse.causticRadius),
                interiorRect.maxX - TapResponse.causticRadius
            ),
            y: min(
                max(point.y, interiorRect.minY + TapResponse.causticRadius),
                interiorRect.maxY - TapResponse.causticRadius
            )
        )
        tapCausticNode.removeAction(forKey: ActionKey.tapCaustic)
        tapCausticNode.position = safePoint
        tapCausticNode.isHidden = false
        tapCausticNode.alpha = 0.62
        tapCausticNode.setScale(expands ? 0.44 : 0.84)
        let action: SKAction = expands
            ? .group([
                .scale(to: 1.22, duration: 0.38),
                .fadeOut(withDuration: 0.38)
            ])
            : .sequence([
                .wait(forDuration: 0.06),
                .fadeOut(withDuration: 0.16)
            ])
        // Hidden at rest: a transparent shape node still costs draws.
        tapCausticNode.run(.sequence([action, .hide()]), withKey: ActionKey.tapCaustic)
    }

    private func playReducedMotionHighlight() {
        reducedMotionHighlightNode.removeAction(forKey: ActionKey.reducedMotionHighlight)
        reducedMotionHighlightNode.alpha = 0
        reducedMotionHighlightNode.isHidden = false
        reducedMotionHighlightNode.run(
            .sequence([
                .fadeAlpha(to: 1, duration: 0.07),
                .wait(forDuration: 0.06),
                .fadeOut(withDuration: 0.14),
                .hide()
            ]),
            withKey: ActionKey.reducedMotionHighlight
        )
    }

    /// Applies a safe gravity vector supplied by Core Motion. Invalid values
    /// are ignored and extreme inputs are clamped before reaching SpriteKit.
    func setGravityVector(
        _ proposed: CGVector,
        smoothing: Bool = true,
        wakesSimulation: Bool = false
    ) {
        guard let clamped = JarTiltMath.clamped(proposed) else { return }
        let next: CGVector
        if smoothing {
            next = JarTiltMath.smoothed(
                from: appliedGravityVector,
                toward: clamped,
                fraction: Constants.Jar.gravitySmoothingFactor
            )
        } else {
            next = clamped
        }
        guard hypot(
            next.dx - appliedGravityVector.dx,
            next.dy - appliedGravityVector.dy
        ) > 0.01 else { return }
        appliedGravityVector = next
        physicsWorld.gravity = next
        applyOpticalTilt(horizontal: next.dx, uptime: tiltClock())
        // Core Motion delivers up to 30 updates per second. Treating every
        // sample as a new interaction used to reset both the three-second
        // settling observation and the tapped gem's low damping, so a held
        // phone could keep the jar alive forever. Sensor gravity now affects
        // only an already-open interaction window. Catalyst's explicit drag
        // opts into waking below.
        if wakesSimulation {
            continueInteractionMotionWindow(
                uptime: ProcessInfo.processInfo.systemUptime
            )
        } else if interactionMotionWindow != nil, isPaused {
            resumeSimulation()
        }
    }

    func resetGravity() {
        setGravityVector(Constants.Jar.gravityVector, smoothing: false)
        // Below the 0.01 sample step the call above keeps the old vector;
        // a reset is exact whatever the last sample was.
        appliedGravityVector = Constants.Jar.gravityVector
        physicsWorld.gravity = Constants.Jar.gravityVector
        // A resting jar returns its light exactly to the level position.
        updateOpticalTilt(horizontal: appliedGravityVector.dx)
    }

    /// Idle tilt (Docs/GemExperienceDesign.md §7.13). While the jar rests,
    /// its physics is paused and its render loop stops (jar-01), so a jar on
    /// a desk costs no frames. Tilt moves the glints and the glass, so while
    /// idle the light follows the phone in steps larger than
    /// `idleTiltRenderThreshold`, at most `idleTiltFramesPerSecond` times a
    /// second: a deliberate tilt still sparkles at once (the step restarts
    /// the render loop and full-rate motion for `motionWakeHold`), while
    /// the sensor noise of a phone held still draws nothing. An awake jar
    /// follows every sample, as before.
    static let idleTiltRenderThreshold: CGFloat = JarTiltMath.idleLightThreshold
    static let idleTiltFramesPerSecond: Double = 30
    /// Clock of the idle tilt gate and of the render loop's redraw and
    /// motion holds (tests inject one).
    var tiltClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var lastIdleTiltUptime: TimeInterval = -.greatestFiniteMagnitude
    /// Light changes made while idle — each one is a frame SpriteKit draws
    /// for a paused jar (tests and the Debug frame probe).
    private(set) var idleTiltFrameCount = 0

    private func applyOpticalTilt(horizontal: CGFloat, uptime: TimeInterval) {
#if DEBUG && targetEnvironment(simulator)
        if JarFrameProbe.disablesIdleTiltGate {
            updateOpticalTilt(horizontal: horizontal)
            return
        }
#endif
        if isIdlePaused {
            guard abs(opticalFraction(horizontal: horizontal) - opticalTiltFraction)
                    > Self.idleTiltRenderThreshold,
                  uptime - lastIdleTiltUptime >= 1 / Self.idleTiltFramesPerSecond - 0.004
            else { return }
            lastIdleTiltUptime = uptime
            let drawn = opticalTiltFraction
            updateOpticalTilt(horizontal: horizontal)
            // A tilt that moved the light keeps the jar drawing and
            // listening closely for a moment.
            if opticalTiltFraction != drawn {
                requestRedraw(for: Self.motionWakeHold)
                holdFullRateMotion()
            }
            return
        }
        updateOpticalTilt(horizontal: horizontal)
    }

    private func opticalFraction(horizontal: CGFloat) -> CGFloat {
        reduceMotion ? CGFloat.zero : JarTiltMath.lightFraction(horizontal: horizontal)
    }

    /// Reflections move a few points opposite the sensed gravity, producing a
    /// lens-like parallax response without rotating text or the whole screen.
    /// Reduce Motion removes this simulated depth while keeping physics stable.
    private func updateOpticalTilt(horizontal: CGFloat) {
        let fraction = opticalFraction(horizontal: horizontal)
        // Unchanged light: touch no node, so a paused jar stays undrawn.
        guard fraction != opticalTiltFraction else { return }
        if isIdlePaused { idleTiltFrameCount &+= 1 }
        opticalTiltFraction = fraction
        glassHighlightNode.position.x = outerJarRect.midX + fraction * 6
        backGlassNode.position.x = fraction * -1.6
        mouthDepthNode.position.x = fraction * -0.55
        innerRimNode.position.x = fraction * 0.35
        updateCollarTilt(fraction)
        livePebbles.forEach { $0.updatePresentationLighting(horizontal: fraction) }
        // A resting jar's render loop is stopped: draw the new light.
        if isIdlePaused { requestRedraw() }
    }

    func resumeSimulation() {
        if isPaused { isPaused = false }
        if isIdlePaused {
            isIdlePaused = false
            onIdlePauseChanged?(false)
            // Samples the idle gate held back are caught up at once.
            updateOpticalTilt(horizontal: appliedGravityVector.dx)
        }
        resetIdleObservation()
        // Landing, fusion, tap, shake, content changes: the render loop and
        // full-rate motion come back in this same turn.
        updateRenderLoop(now: tiltClock())
    }

    // MARK: Render loop and motion demand (jar-01, §7.13)

    /// Draws the resting jar again for `hold` seconds without waking its
    /// physics: a light-only change (tilt, a setting, a new gem bed), a view
    /// that must show the settled frame (a new SKView, a return to the
    /// foreground) or a snapshot. An awake jar renders anyway.
    func requestRedraw(for hold: TimeInterval = JarScene.redrawHold) {
        let now = tiltClock()
        redrawUntil = max(redrawUntil, now + max(0, hold))
        updateRenderLoop(now: now)
    }

    /// Keeps device motion at the full rate for `hold` seconds while the jar
    /// rests: after a tilt that moved the light, or the first peak of a
    /// shake (its reversal must not fall between idle samples).
    func holdFullRateMotion(for hold: TimeInterval = JarScene.motionWakeHold) {
        let now = tiltClock()
        motionWakeUntil = max(motionWakeUntil, now + max(0, hold))
        updateRenderLoop(now: now)
    }

    /// Resolves the render loop and the motion demand from the idle pause
    /// and the open holds, applies them, and schedules the check that ends
    /// the holds (a paused scene gets no `update(_:)` to do it).
    private func updateRenderLoop(now: TimeInterval) {
        var paused = isIdlePaused && now >= redrawUntil
        var fullRate = !isIdlePaused || now < motionWakeUntil
#if DEBUG && targetEnvironment(simulator)
        if JarIdleEnergyDebug.keepsRestingJarAwake {
            paused = false
            fullRate = true
        }
#endif
        isRenderLoopPaused = paused
        applyRenderLoopState()
        if fullRateMotionDemand.value != fullRate {
            fullRateMotionDemand.send(fullRate)
        }
        let deadline = max(redrawUntil, motionWakeUntil)
        if isIdlePaused, now < deadline {
            scheduleRenderLoopCheck(after: deadline - now)
        }
    }

    /// Applies the render loop state to the SKView again. SwiftUI owns the
    /// view and may re-create or update it (for example when its frame
    /// rate changes with Low Power Mode); the owner calls this after such a
    /// change so a resting jar's stopped loop never silently restarts
    /// (jar-01).
    func reassertRenderLoopState() {
        applyRenderLoopState()
    }

    /// The SKView un-pauses its scene together with itself (measured), so a
    /// light-only redraw re-freezes the resting physics in the same turn,
    /// before any frame can step it.
    private func applyRenderLoopState() {
        if let view, view.isPaused != isRenderLoopPaused {
            view.isPaused = isRenderLoopPaused
        }
        if isIdlePaused, !isPaused {
            isPaused = true
        }
    }

    private func scheduleRenderLoopCheck(after delay: TimeInterval) {
        guard !isRenderLoopCheckScheduled else { return }
        isRenderLoopCheckScheduled = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + min(max(delay, 0.02), 1)
        ) { [weak self] in
            guard let self else { return }
            self.isRenderLoopCheckScheduled = false
            self.updateRenderLoop(now: self.tiltClock())
        }
    }

#if DEBUG
    /// Deterministic seam: re-resolves the render loop and the motion demand
    /// at the injected `tiltClock`, as the scheduled check would.
    func evaluateRenderLoopForTesting() {
        updateRenderLoop(now: tiltClock())
    }
#endif

    private func beginInteractionMotionWindow(uptime: TimeInterval) {
        interactionMotionWindow = JarInteractionMotionWindow(openedAt: uptime)
        resumeSimulation()
    }

    /// Continues an explicit pointer drag without resetting the settling
    /// sample on every event. A new drag still opens a complete window and can
    /// wake a previously settled Catalyst scene.
    private func continueInteractionMotionWindow(uptime: TimeInterval) {
        let wasActive = interactionMotionWindow != nil
        interactionMotionWindow = JarInteractionMotionWindow(openedAt: uptime)
        if isPaused || isIdlePaused {
            resumeSimulation()
        } else if !wasActive {
            resetIdleObservation()
        }
    }

    override func update(_ currentTime: TimeInterval) {
        super.update(currentTime)
#if DEBUG && targetEnvironment(simulator)
        JarFrameProbe.shared?.sceneUpdated()
#endif
        let capacity = StrataMath.capacityUnits(pebbleRadii: bakeEligibleRadii)
        if capacity >= Constants.Jar.aggregateCapacityUnits {
            isCapacityReliefActive = true
        } else if capacity <= Constants.Jar.postAggregateCapacityUnits {
            isCapacityReliefActive = false
        }
        if !isBakeInProgress, needsAggregation {
            _ = beginBakeIfNeeded(force: false)
        }
        hasRenderedFrame = true
        if appliesScheduledJarScale, let scheduled = scheduledJarScale {
            applyJarScale(scheduled, animated: true)
        }
        processDropQueue()
        publishPhysicalContentChangeIfNeeded()
        updateRareTwinkles()
        updateGemTwinkles(now: currentTime)
        if abs(currentTime - lastPileLightRefresh) >= 0.5 {
            lastPileLightRefresh = currentTime
            refreshPileLight()
            publishSettledPileTop()
        }
        updateIdlePause(
            currentTime: currentTime,
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    override func didSimulatePhysics() {
        super.didSimulatePhysics()
        updateTapPresentationTrackingIfNeeded()
        for pebble in livePebbles where aboveEntryPebbleIDs.contains(pebble.descriptor.id) {
            if pebble.position.y + pebble.radius <= interiorRect.maxY {
                finishCompletionEntryPhysics(for: pebble)
            }
        }
        updateCompletionDropTrackingIfNeeded()
        advancePendingTapLaunchIfNeeded()
        livePebbles.forEach {
            $0.updatePresentationLighting(horizontal: opticalTiltFraction)
        }
    }

#if DEBUG && targetEnvironment(simulator)
    override func didFinishUpdate() {
        super.didFinishUpdate()
        JarFrameProbe.shared?.sceneFinishedUpdate()
    }
#endif

    /// A sleeping floor contact can consume a newly assigned upward velocity
    /// during the same SpriteKit step. Reassert it for three frames, then retain
    /// only a frame-counted flight gate while SpriteKit owns every collision.
    /// This prevents a slow render loop from shortening the visible trajectory.
    private func advancePendingTapLaunchIfNeeded() {
        guard var pendingTapKick,
              transientMotionGate.accepts(pendingTapKick.sequence),
              pendingTapKick.remainingFlightFrames > 0,
              let driven = pendingTapKick.kicks.first,
              let pebble = livePebbles.first(where: {
                  $0.descriptor.id == driven.key
              }),
              !pebble.isRemovedForBake,
              let body = pebble.physicsBody
        else {
            self.pendingTapKick = nil
            return
        }

        if pendingTapKick.remainingReinforcementFrames > 0 {
            let kick = driven.value
            body.isDynamic = true
            body.isResting = false
            body.usesPreciseCollisionDetection = true
            body.linearDamping = TapResponse.flightDamping
            body.velocity = kick.velocity
            body.angularVelocity = kick.angularVelocity
            pendingTapKick.remainingReinforcementFrames -= 1
        }

        pendingTapKick.remainingFlightFrames -= 1
        self.pendingTapKick = pendingTapKick.remainingFlightFrames > 0
            ? pendingTapKick
            : nil
    }

    nonisolated func didBegin(_ contact: SKPhysicsContact) {
        MainActor.assumeIsolated {
            handleContact(contact)
        }
    }

    private func handleContact(_ contact: SKPhysicsContact) {
        let nodeA = contact.bodyA.node as? PebbleNode
        let nodeB = contact.bodyB.node as? PebbleNode
        let candidates = [nodeA, nodeB].compactMap { $0 }
        guard !candidates.isEmpty else { return }

        var deliveredLanding = false
        for pebble in candidates where !pebble.hasLanded {
            let otherBody = contact.bodyA.node === pebble ? contact.bodyB : contact.bodyA
            let isFloor = otherBody.categoryBitMask & JarPhysicsCategory.floor != .zero
            let otherPebble = otherBody.node as? PebbleNode
            let isSettledPebble = otherPebble?.hasLanded == true
            guard isFloor || isSettledPebble else { continue }

            let velocity = abs(pebble.physicsBody?.velocity.dy ?? .zero)
            let impulseSpeed = contact.collisionImpulse / max(pebble.physicsBody?.mass ?? 1, 1)
            let impactSpeed = max(velocity, impulseSpeed)
            pebble.markLanded()
            if scheduledJarScale != nil {
                // Rescaling inside the contact callback would resize bodies
                // mid-step; the next update applies it.
                appliesScheduledJarScale = true
            }
            finishCompletionEntryPhysics(for: pebble)
            aboveEntryPebbleIDs.remove(pebble.descriptor.id)
            updateCompletionDropTrackingIfNeeded()
            if mutedLandingIDs.remove(pebble.descriptor.id) != nil {
                deliveredLanding = true
                continue
            }
            deliverLandingFeedback(
                for: pebble,
                speed: max(impactSpeed, Constants.Jar.minimumLandingSpeed),
                point: contact.contactPoint
            )
            deliveredLanding = true
        }

        let contactContainsMutedPebble = candidates.contains {
            mutedLandingIDs.contains($0.descriptor.id)
        }
        if !deliveredLanding, !contactContainsMutedPebble {
            secondaryFeedback(for: contact, pebbles: candidates)
        }
    }

    private func installSceneGraph() {
        guard worldNode.parent == nil else { return }
        addChild(worldNode)
        strataRenderer.install(in: worldNode)

        jarShadowNode.name = "jar.shadow"
        backGlassNode.name = "jar.glass.back"
        mouthDepthNode.name = "jar.mouth.depth"
        wallNode.name = "jar.walls"
        floorNode.name = "jar.floor"
        glassNode.name = "jar.glass.front"
        glassHighlightNode.name = "jar.glass.highlights"
        reducedMotionHighlightNode.name = "jar.reducedMotion.highlight"
        rimNode.name = "jar.glass.rim"
        innerRimNode.name = "jar.glass.innerRim"
        tapCausticNode.name = "jar.tap.caustic"
        floorGlowNode.name = "jar.floorGlow"
        pileGlowNode.name = "jar.pileGlow"
        gemBedNode.name = "jar.gemBed"
        collarNode.name = "jar.collar"
        collarCenterNode.name = "jar.collar.center"
        collarLeftNode.name = "jar.collar.left"
        collarRightNode.name = "jar.collar.right"
        // Glass v2 is three pre-rendered layers (back, front, moving
        // highlights) plus the mouth rim; the former thin stroke nodes
        // (specular, warm reflection, lens shade, base arcs) are gone.
        worldNode.addChild(jarShadowNode)
        worldNode.addChild(backGlassNode)
        worldNode.addChild(mouthDepthNode)
        worldNode.addChild(wallNode)
        worldNode.addChild(floorNode)
        worldNode.addChild(glassNode)
        worldNode.addChild(glassHighlightNode)
        worldNode.addChild(reducedMotionHighlightNode)
        worldNode.addChild(collarNode)
        collarNode.addChild(collarLeftNode)
        collarNode.addChild(collarCenterNode)
        collarNode.addChild(collarRightNode)
        worldNode.addChild(rimNode)
        worldNode.addChild(innerRimNode)
        worldNode.addChild(tapCausticNode)
        worldNode.addChild(floorGlowNode)
        worldNode.addChild(gemBedNode)
        worldNode.addChild(pileGlowNode)
        // Ordinary alpha: the bed is decoration that must survive the
        // transparent snapshot as drawn, and it sits between the floor glow
        // (below) and the pile light (above), behind every body.
        gemBedNode.blendMode = .alpha
        gemBedNode.anchorPoint = CGPoint(x: 0.5, y: 0)
        gemBedNode.zPosition = JarZPosition.strata + 0.55
        gemBedNode.isHidden = true
        pileGlowNode.blendMode = .add
        pileGlowNode.colorBlendFactor = 1
        pileGlowNode.alpha = 0
        // Behind the gem bed: the pile's light rises around the bodies and
        // through the bed's gaps, but never tints one side of the bed.
        pileGlowNode.zPosition = JarZPosition.strata + 0.52

        cameraNode.position = cameraRestPosition
        addChild(cameraNode)
        camera = cameraNode
        rebuildGeometry()
    }

    private func observeAccessibilitySettings() {
        reduceTransparencyObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let enabled = UIAccessibility.isReduceTransparencyEnabled
                self.reduceTransparency = enabled
                self.allPebbleNodes.forEach { $0.setReduceTransparency(enabled) }
                self.floorGlowNode.alpha = enabled ? 0.12 : 0.28
                self.refreshPileLight()
                self.requestRedraw()
            }
        }
        reduceMotionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reduceMotion = UIAccessibility.isReduceMotionEnabled
            }
        }
        differentiateWithoutColorObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.differentiateWithoutColorDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.setThemeMarks(GemThemeMark.isSystemEnabled)
            }
        }
    }

    /// Differentiate Without Color: every study gem and crystal re-bakes
    /// with (or without) its theme mark (§7.12). A jar resting in its idle
    /// pause draws one more settled frame so the change shows at once.
    func setThemeMarks(_ enabled: Bool) {
        allPebbleNodes.forEach { $0.setThemeMarks(enabled) }
        // A light-only change: draw it without waking the physics.
        requestRedraw()
    }

    private func rebuildGeometry() {
        guard size.width > .zero, size.height > .zero else { return }
        // A new stage size (or a new view) shows even on a resting jar.
        requestRedraw()
        let outer = outerJarRect
        if cameraNode.action(forKey: ActionKey.cameraShake) == nil {
            cameraNode.position = cameraRestPosition
        }
        let jarPath = makeJarPath(in: outer)

        jarShadowNode.path = CGPath(
            ellipseIn: CGRect(
                x: outer.minX + outer.width * 0.07,
                y: outer.minY - 15,
                width: outer.width * 0.86,
                height: 36
            ),
            transform: nil
        )
        // A light contact shadow only: the floor under the jar is lit by the
        // pile (SwiftUI stage), not a dark shelf.
        jarShadowNode.fillColor = UIColor.black.withAlphaComponent(0.20)
        jarShadowNode.strokeColor = .clear
        jarShadowNode.glowWidth = 10
        jarShadowNode.zPosition = JarZPosition.background - 2

        // Glass v2: back and front are pre-rendered per jar size (cached),
        // so the bottle is a handful of textured draws instead of a dozen
        // hairline strokes.
        let glassTextures = Self.glassTextures(for: outer.size, neckInset: neckInset)
        backGlassNode.path = jarPath
        backGlassNode.fillColor = .white
        backGlassNode.fillTexture = glassTextures.back
        backGlassNode.strokeColor = .clear
        backGlassNode.lineWidth = 0
        backGlassNode.glowWidth = 0
        backGlassNode.zPosition = JarZPosition.background

        let mouthRect = CGRect(
            x: outer.minX + neckInset - 1,
            y: outer.maxY - 8,
            width: outer.width - neckInset * 2 + 2,
            height: 18
        )
        mouthDepthNode.path = CGPath(ellipseIn: mouthRect, transform: nil)
        mouthDepthNode.fillColor = JarPalette.mouthDepth
        mouthDepthNode.strokeColor = JarPalette.specular.withAlphaComponent(0.30)
        mouthDepthNode.lineWidth = 1.6
        mouthDepthNode.glowWidth = 0
        mouthDepthNode.zPosition = JarZPosition.background + 0.6

        glassNode.path = jarPath
        glassNode.fillColor = .white
        glassNode.fillTexture = glassTextures.front
        // The silhouette is carried by the thick-glass rims in the texture.
        glassNode.strokeColor = .clear
        glassNode.lineWidth = 0
        glassNode.glowWidth = 0
        glassNode.zPosition = JarZPosition.glass

        glassHighlightNode.texture = glassTextures.highlights
        glassHighlightNode.size = outer.size
        glassHighlightNode.position = CGPoint(x: outer.midX + opticalTiltFraction * 6, y: outer.midY)
        glassHighlightNode.blendMode = .add
        glassHighlightNode.zPosition = JarZPosition.glass + 0.4

        reducedMotionHighlightNode.path = jarPath
        reducedMotionHighlightNode.fillColor = UIColor.white.withAlphaComponent(0.11)
        reducedMotionHighlightNode.strokeColor = JarPalette.specular.withAlphaComponent(0.34)
        reducedMotionHighlightNode.lineWidth = 2.2
        reducedMotionHighlightNode.glowWidth = 1.4
        if reducedMotionHighlightNode.action(
            forKey: ActionKey.reducedMotionHighlight
        ) == nil {
            reducedMotionHighlightNode.alpha = 0
            reducedMotionHighlightNode.isHidden = true
        }
        reducedMotionHighlightNode.zPosition = JarZPosition.glass + 0.72

        rimNode.path = CGPath(
            ellipseIn: CGRect(
                x: outer.minX + neckInset - 2,
                y: outer.maxY - 6,
                width: outer.width - neckInset * 2 + 4,
                height: 12
            ),
            transform: nil
        )
        rimNode.fillColor = JarPalette.mouthDepth.withAlphaComponent(0.42)
        rimNode.strokeColor = JarPalette.specular.withAlphaComponent(0.70)
        rimNode.lineWidth = 1.8
        rimNode.glowWidth = 0
        rimNode.zPosition = JarZPosition.glass + 1.2

        innerRimNode.path = CGPath(
            ellipseIn: mouthRect.insetBy(dx: 4.5, dy: 3.2),
            transform: nil
        )
        innerRimNode.fillColor = .clear
        innerRimNode.strokeColor = JarPalette.warmSpecular.withAlphaComponent(0.22)
        innerRimNode.lineWidth = 0.9
        innerRimNode.glowWidth = 0
        innerRimNode.zPosition = JarZPosition.glass + 1.35

        tapCausticNode.path = CGPath(
            ellipseIn: CGRect(
                x: -TapResponse.causticRadius,
                y: -TapResponse.causticRadius * 0.42,
                width: TapResponse.causticRadius * 2,
                height: TapResponse.causticRadius * 0.84
            ),
            transform: nil
        )
        tapCausticNode.fillColor = .clear
        tapCausticNode.strokeColor = JarPalette.warmSpecular.withAlphaComponent(0.72)
        tapCausticNode.lineWidth = 1.1
        tapCausticNode.glowWidth = 3.2
        tapCausticNode.alpha = 0
        if tapCausticNode.action(forKey: ActionKey.tapCaustic) == nil {
            tapCausticNode.isHidden = true
        }
        tapCausticNode.zPosition = JarZPosition.glass + 1.5

        rebuildCollar()

        floorGlowNode.size = CGSize(width: outer.width * 0.98, height: 72)
        floorGlowNode.position = CGPoint(x: outer.midX, y: interiorRect.minY + 4)
        floorGlowNode.color = UIColor(red: 1, green: 0.62, blue: 0.42, alpha: 1)
        floorGlowNode.colorBlendFactor = 1
        floorGlowNode.blendMode = .add
        floorGlowNode.alpha = reduceTransparency ? 0.12 : 0.28
        floorGlowNode.zPosition = JarZPosition.strata + 0.5
        refreshGemBed()

        wallNode.removeAllChildren()
        addStaticEdge(
            from: CGPoint(x: interiorRect.minX, y: interiorRect.minY),
            to: CGPoint(x: interiorRect.minX, y: shoulderStartY),
            category: JarPhysicsCategory.wall,
            parent: wallNode
        )
        addStaticEdge(
            from: CGPoint(x: interiorRect.minX, y: shoulderStartY),
            to: CGPoint(x: neckInteriorMinX, y: neckBaseY),
            category: JarPhysicsCategory.wall,
            parent: wallNode
        )
        addStaticEdge(
            from: CGPoint(x: neckInteriorMinX, y: neckBaseY),
            to: CGPoint(x: neckInteriorMinX, y: interiorRect.maxY),
            category: JarPhysicsCategory.wall,
            parent: wallNode
        )
        addStaticEdge(
            from: CGPoint(x: neckInteriorMinX, y: interiorRect.maxY),
            to: CGPoint(x: neckInteriorMaxX, y: interiorRect.maxY),
            category: JarPhysicsCategory.wall,
            parent: wallNode
        )
        addStaticEdge(
            from: CGPoint(x: neckInteriorMaxX, y: interiorRect.maxY),
            to: CGPoint(x: neckInteriorMaxX, y: neckBaseY),
            category: JarPhysicsCategory.wall,
            parent: wallNode
        )
        addStaticEdge(
            from: CGPoint(x: neckInteriorMaxX, y: neckBaseY),
            to: CGPoint(x: interiorRect.maxX, y: shoulderStartY),
            category: JarPhysicsCategory.wall,
            parent: wallNode
        )
        addStaticEdge(
            from: CGPoint(x: interiorRect.maxX, y: shoulderStartY),
            to: CGPoint(x: interiorRect.maxX, y: interiorRect.minY),
            category: JarPhysicsCategory.wall,
            parent: wallNode
        )

        renderBaseLayers()
        rebuildFloor()
        rescuePebblesInsideWalls()
    }

    private func makeJarPath(in rect: CGRect) -> CGPath {
        Self.jarPath(in: rect, neckInset: neckInset)
    }

    /// Neck inset of a bottle `width` wide (the mouth is narrower by this
    /// on both sides).
    nonisolated static func neckInset(jarWidth width: CGFloat) -> CGFloat {
        min(50, width * 0.14)
    }

    /// The bottle silhouette in `rect` (y up, like the scene). SwiftUI layers
    /// and share art flip it to draw the same bottle.
    nonisolated static func jarPath(in rect: CGRect, neckInset: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let bottomRadius = min(Constants.Jar.cornerRadius * 1.30, rect.width * 0.12)
        let shoulderDepth = min(52, rect.height * 0.13)
        let neckHeight = min(16, rect.height * 0.04)
        let mouthLeft = rect.minX + neckInset
        let mouthRight = rect.maxX - neckInset

        path.move(to: CGPoint(x: rect.minX + bottomRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - bottomRadius, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + bottomRadius),
            control1: CGPoint(x: rect.maxX - bottomRadius * 0.34, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + bottomRadius * 0.34)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - shoulderDepth))
        path.addCurve(
            to: CGPoint(x: mouthRight, y: rect.maxY - neckHeight),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - shoulderDepth * 0.42),
            control2: CGPoint(x: mouthRight + 12, y: rect.maxY - neckHeight - 8)
        )
        path.addLine(to: CGPoint(x: mouthRight, y: rect.maxY))
        path.addLine(to: CGPoint(x: mouthLeft, y: rect.maxY))
        path.addLine(to: CGPoint(x: mouthLeft, y: rect.maxY - neckHeight))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - shoulderDepth),
            control1: CGPoint(x: mouthLeft - 12, y: rect.maxY - neckHeight - 8),
            control2: CGPoint(x: rect.minX, y: rect.maxY - shoulderDepth * 0.42)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + bottomRadius))
        path.addCurve(
            to: CGPoint(x: rect.minX + bottomRadius, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + bottomRadius * 0.34),
            control2: CGPoint(x: rect.minX + bottomRadius * 0.34, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }

    private struct GlassTextures {
        let back: SKTexture
        let front: SKTexture
        let highlights: SKTexture
    }

    private static let glassTextureCache = NSCache<NSString, NSArray>()

    /// Glass v2 (Docs/GemExperienceDesign.md §7.8), pre-rendered once per jar
    /// size. Back: absorption tint and inner shadows. Front: 7 pt wall band,
    /// warm left rim, cool right rim with a lower-right flare, a 14 pt base
    /// lens with its caustic line, neck ridges and a faint outline.
    /// Highlights (additive, moved ±6 pt with tilt): two vertical reflection
    /// bands and the shoulder light. No SKEffectNode or CIFilter.
    private static func glassTextures(for size: CGSize, neckInset: CGFloat) -> GlassTextures {
        let width = max(1, size.width.rounded())
        let height = max(1, size.height.rounded())
        let key = NSString(string: "\(Int(width))x\(Int(height))-\(Int(neckInset.rounded()))")
        if let cached = glassTextureCache.object(forKey: key) as? [SKTexture], cached.count == 3 {
            return GlassTextures(back: cached[0], front: cached[1], highlights: cached[2])
        }
        let renderSize = CGSize(width: width, height: height)
        // Jar path in y-down texture space.
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        let outline = jarPath(
            in: CGRect(origin: .zero, size: renderSize),
            neckInset: neckInset
        ).copy(using: &flip) ?? CGPath(rect: CGRect(origin: .zero, size: renderSize), transform: nil)
        let space = CGColorSpaceCreateDeviceRGB()
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        let warm = JarPalette.color(hex: Constants.Color.auroraWarm)
        let peach = JarPalette.color(hex: "#FFB38A")
        let cool = JarPalette.color(hex: Constants.Color.auroraCool)
        let blue = JarPalette.color(hex: Constants.Color.floorGlow)
        let shoulderY = min(52, height * 0.13)
        let neckHeight = min(16, height * 0.04)

        /// Soft inner glow along the silhouette: widening strokes clipped to
        /// the interior, masked to one side by a horizontal gradient.
        func innerRim(
            _ context: CGContext,
            colors: [UIColor],
            alpha: CGFloat,
            depth: CGFloat,
            fromLeft: Bool
        ) {
            context.saveGState()
            context.addPath(outline)
            context.clip()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            let passes = 6
            for pass in 0 ..< passes {
                let t = CGFloat(pass) / CGFloat(passes - 1)
                let color = colors[min(colors.count - 1, Int(t * CGFloat(colors.count - 1) + 0.5))]
                context.setStrokeColor(color.withAlphaComponent(alpha * pow(1 - t, 1.6) * 0.55).cgColor)
                context.setLineWidth(max(1, depth * 2 * (0.12 + t)))
                context.addPath(outline)
                context.strokePath()
            }
            // Side mask.
            context.setBlendMode(.destinationIn)
            let mask = [
                UIColor(white: 1, alpha: 1).cgColor,
                UIColor(white: 1, alpha: 0.35).cgColor,
                UIColor(white: 1, alpha: 0).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: mask, locations: [0, 0.30, 0.56]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: fromLeft ? 0 : width, y: 0),
                    end: CGPoint(x: fromLeft ? width : 0, y: 0),
                    options: []
                )
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }

        let back = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.addPath(outline)
            context.clip()
            // Absorption follows the path length through the back wall:
            // clear in the middle (where the time core glows through), deeper
            // toward the side walls.
            let absorption = JarPalette.color(hex: Constants.Color.glassAbsorption)
            let wall = [
                absorption.withAlphaComponent(0.20).cgColor,
                absorption.withAlphaComponent(0.10).cgColor,
                absorption.withAlphaComponent(0.06).cgColor,
                absorption.withAlphaComponent(0.10).cgColor,
                absorption.withAlphaComponent(0.20).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: wall, locations: [0, 0.28, 0.5, 0.72, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: height / 2),
                    end: CGPoint(x: width, y: height / 2),
                    options: []
                )
            }
            // Inner shadow in the lower back corners and under the shoulders.
            for center in [
                CGPoint(x: 0, y: height), CGPoint(x: width, y: height),
                CGPoint(x: width * 0.08, y: shoulderY + 10), CGPoint(x: width * 0.92, y: shoulderY + 10)
            ] {
                let shade = [
                    UIColor(red: 0.01, green: 0.02, blue: 0.06, alpha: 0.18).cgColor,
                    UIColor(red: 0.01, green: 0.02, blue: 0.06, alpha: 0).cgColor
                ] as CFArray
                if let gradient = CGGradient(colorsSpace: space, colors: shade, locations: [0, 1]) {
                    context.drawRadialGradient(
                        gradient,
                        startCenter: center, startRadius: 0,
                        endCenter: center, endRadius: width * 0.22,
                        options: []
                    )
                }
            }
            // Faint back wall contour seen through the front.
            context.setStrokeColor(JarPalette.color(hex: Constants.Color.auroraViolet).withAlphaComponent(0.16).cgColor)
            context.setLineWidth(2)
            context.addPath(outline)
            context.strokePath()
        }

        let front = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.saveGState()
            context.addPath(outline)
            context.clip()
            // Very light body tint: a hint of warm left, cool right.
            let body = [
                warm.withAlphaComponent(0.05).cgColor,
                UIColor.clear.cgColor,
                cool.withAlphaComponent(0.05).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: body, locations: [0, 0.5, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: height / 2),
                    end: CGPoint(x: width, y: height / 2),
                    options: []
                )
            }
            // Wall thickness: a 7 pt cool band inside the silhouette.
            context.setStrokeColor(cool.withAlphaComponent(0.18).cgColor)
            context.setLineWidth(14)
            context.addPath(outline)
            context.strokePath()
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.10).cgColor)
            context.setLineWidth(15.5)
            context.addPath(outline)
            context.replacePathWithStrokedPath()
            context.setLineWidth(0.8)
            context.strokePath()

            // Base lens: 14 pt thick, a dark refraction band over a bright
            // caustic line at the floor the gems rest on.
            let lensTop = height - 14
            let refraction = [
                UIColor(red: 0.04, green: 0.06, blue: 0.16, alpha: 0).cgColor,
                UIColor(red: 0.04, green: 0.06, blue: 0.16, alpha: 0.12).cgColor,
                UIColor(red: 0.30, green: 0.40, blue: 0.62, alpha: 0.14).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: refraction, locations: [0, 0.35, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: lensTop - 6),
                    end: CGPoint(x: 0, y: height),
                    options: []
                )
            }
            let caustic = [
                UIColor.clear.cgColor,
                warm.withAlphaComponent(0.75).cgColor,
                UIColor.white.withAlphaComponent(0.85).cgColor,
                cool.withAlphaComponent(0.75).cgColor,
                UIColor.clear.cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: space,
                colors: caustic,
                locations: [0.04, 0.26, 0.5, 0.74, 0.96]
            ) {
                for (y, thickness, alpha) in [(height - 10, CGFloat(2), CGFloat(1)), (height - 2.5, CGFloat(1.2), CGFloat(0.7))] {
                    context.saveGState()
                    context.setAlpha(alpha)
                    context.clip(to: CGRect(x: 0, y: y - thickness / 2, width: width, height: thickness))
                    context.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: 0, y: y),
                        end: CGPoint(x: width, y: y),
                        options: []
                    )
                    context.restoreGState()
                }
            }

            // Neck ridges just under the collar: two thin lit lines.
            for offset in [CGFloat(3), 7] {
                let y = neckHeight + offset
                let ridge = CGMutablePath()
                ridge.move(to: CGPoint(x: neckInset - 4, y: y))
                ridge.addQuadCurve(
                    to: CGPoint(x: width - neckInset + 4, y: y),
                    control: CGPoint(x: width / 2, y: y + 3)
                )
                context.setStrokeColor(UIColor.white.withAlphaComponent(offset < 5 ? 0.22 : 0.12).cgColor)
                context.setLineWidth(0.8)
                context.addPath(ridge)
                context.strokePath()
            }
            context.restoreGState()

            // Warm left rim (coral → peach) and cool right rim (cyan → blue):
            // thick glass that glows from within.
            innerRim(context, colors: [warm, peach], alpha: 1, depth: 15, fromLeft: true)
            innerRim(context, colors: [cool, blue], alpha: 0.95, depth: 15, fromLeft: false)

            // Wall specular lines (round 12): down each wall, from the
            // shoulder to 75 % of the height, fading at both ends, a 1.5 pt
            // white core (α0.95) in a 5 pt glow (α0.25).
            context.saveGState()
            for (x, alpha) in [(CGFloat(5.5), CGFloat(0.95)), (width - 5.5, CGFloat(0.95))] {
                let top = shoulderY + 8
                let bottom = height * 0.75
                for (lineWidth, lineAlpha) in [(CGFloat(5), CGFloat(0.25)), (CGFloat(1.5), alpha)] {
                    context.saveGState()
                    context.clip(to: CGRect(x: x - lineWidth / 2, y: top, width: lineWidth, height: bottom - top))
                    let line = [
                        UIColor.white.withAlphaComponent(0).cgColor,
                        UIColor.white.withAlphaComponent(lineAlpha).cgColor,
                        UIColor.white.withAlphaComponent(lineAlpha * 0.85).cgColor,
                        UIColor.white.withAlphaComponent(0).cgColor
                    ] as CFArray
                    if let gradient = CGGradient(colorsSpace: space, colors: line, locations: [0, 0.16, 0.72, 1]) {
                        context.drawLinearGradient(
                            gradient,
                            start: CGPoint(x: x, y: top),
                            end: CGPoint(x: x, y: bottom),
                            options: []
                        )
                    }
                    context.restoreGState()
                }
            }
            context.restoreGState()

            // Lower-right flare streak in the cool rim.
            context.saveGState()
            context.addPath(outline)
            context.clip()
            let flare = [
                UIColor.white.withAlphaComponent(0.55).cgColor,
                cool.withAlphaComponent(0.22).cgColor,
                UIColor.clear.cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: flare, locations: [0, 0.35, 1]) {
                context.translateBy(x: width - 4, y: height * 0.80)
                context.scaleBy(x: 0.10, y: 1)
                context.drawRadialGradient(
                    gradient,
                    startCenter: .zero, startRadius: 0,
                    endCenter: .zero, endRadius: height * 0.16,
                    options: []
                )
            }
            context.restoreGState()

            // Faint outline so the silhouette stays legible on Dawn.
            context.setStrokeColor(JarPalette.color(hex: Constants.Color.glassEdge).withAlphaComponent(0.32).cgColor)
            context.setLineWidth(1)
            context.addPath(outline)
            context.strokePath()
        }

        let highlights = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.addPath(outline)
            context.clip()
            // Two soft vertical reflection bands (0.2 and 0.75 of the width).
            for (center, bandWidth) in [(width * 0.20, width * 0.05), (width * 0.75, width * 0.03)] {
                let band = [
                    UIColor.white.withAlphaComponent(0.12).cgColor,
                    UIColor.white.withAlphaComponent(0.06).cgColor,
                    UIColor.clear.cgColor
                ] as CFArray
                guard let gradient = CGGradient(colorsSpace: space, colors: band, locations: [0, 0.6, 1]) else { continue }
                context.saveGState()
                context.translateBy(x: center, y: height * 0.52)
                context.scaleBy(x: 1, y: height * 0.36 / max(bandWidth, 1))
                context.drawRadialGradient(
                    gradient,
                    startCenter: .zero, startRadius: 0,
                    endCenter: .zero, endRadius: bandWidth,
                    options: []
                )
                context.restoreGState()
            }
            // Specular streaks on the glass (round 12): the window light
            // seen in the front wall, 18 % in from the left and 10 % in
            // from the right, from the shoulder to 75 % of the height: a
            // 2 pt white core (α0.85) in an 8 pt glow (α0.3), tapered at
            // both ends. Additive, so they ride the tilt with the bands.
            for (center, alpha) in [(width * 0.18, CGFloat(0.85)), (width * 0.90, CGFloat(0.8))] {
                let top = shoulderY + 12
                let bottom = height * 0.75
                for (lineWidth, lineAlpha) in [(CGFloat(8), CGFloat(0.3)), (CGFloat(2), alpha)] {
                    context.saveGState()
                    context.clip(to: CGRect(x: center - lineWidth / 2, y: top, width: lineWidth, height: bottom - top))
                    let streak = [
                        UIColor.white.withAlphaComponent(0).cgColor,
                        UIColor.white.withAlphaComponent(lineAlpha).cgColor,
                        UIColor.white.withAlphaComponent(lineAlpha * 0.7).cgColor,
                        UIColor.white.withAlphaComponent(0).cgColor
                    ] as CFArray
                    if let gradient = CGGradient(colorsSpace: space, colors: streak, locations: [0, 0.2, 0.62, 1]) {
                        context.drawLinearGradient(
                            gradient,
                            start: CGPoint(x: center, y: top),
                            end: CGPoint(x: center, y: bottom),
                            options: []
                        )
                    }
                    context.restoreGState()
                }
            }
            // Shoulder light on the right shoulder, a warmer one left, each
            // with a white specular core along the curve (round 12).
            for (fromLeft, color, alpha) in [(false, GemColor(cool).mixed(with: .white, amount: 0.7).withAlpha(1), CGFloat(0.9)), (true, GemColor(peach).mixed(with: .white, amount: 0.55).withAlpha(1), CGFloat(0.72))] {
                let x0 = fromLeft ? neckInset * 0.55 : width - neckInset * 0.55
                let arc = CGMutablePath()
                arc.move(to: CGPoint(x: fromLeft ? neckInset - 2 : width - neckInset + 2, y: neckHeight + 4))
                arc.addQuadCurve(
                    to: CGPoint(x: fromLeft ? 6 : width - 6, y: shoulderY + 6),
                    control: CGPoint(x: x0, y: neckHeight + 6)
                )
                context.setLineCap(.round)
                for pass in 0 ..< 3 {
                    context.setStrokeColor(color.withAlphaComponent(alpha * [0.22, 0.4, 1][pass]).cgColor)
                    context.setLineWidth([7, 4, 1.6][pass])
                    context.addPath(arc)
                    context.strokePath()
                }
            }
        }

        let textures = [back, front, highlights].map { image -> SKTexture in
            let texture = SKTexture(image: image)
            texture.filteringMode = .linear
            return texture
        }
        glassTextureCache.setObject(textures as NSArray, forKey: key)
        return GlassTextures(back: textures[0], front: textures[1], highlights: textures[2])
    }

    // MARK: Copper collar

    private static let collarTextureCache = NSCache<NSString, SKTexture>()

    /// Rose-gold band around the neck: base #B8735A, highlight #F2C4A8,
    /// shade #5A2E22 (engravings only), two white specular bands, vertical
    /// anisotropic highlight bands whose position follows the tilt state,
    /// and up to six engraved milestone marks on the lower edge. The mouth
    /// stays open.
    private static func collarTexture(width: CGFloat, tilt: Int, marks: Int) -> SKTexture {
        let key = NSString(string: "\(Int(width.rounded()))-\(tilt)-\(marks)")
        if let cached = collarTextureCache.object(forKey: key) { return cached }
        let height: CGFloat = 14
        let size = CGSize(width: width, height: height + 3)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.preferredRange = .standard
        let base = JarPalette.color(hex: "#B8735A")
        let highlight = JarPalette.color(hex: "#F2C4A8")
        let shade = JarPalette.color(hex: "#5A2E22")
        let image = UIGraphicsImageRenderer(size: size, format: format).image { rendererContext in
            let context = rendererContext.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            // Cylinder band: both edges bow toward the viewer.
            let band = CGMutablePath()
            band.move(to: CGPoint(x: 0, y: 1.5))
            band.addQuadCurve(to: CGPoint(x: width, y: 1.5), control: CGPoint(x: width / 2, y: 3.2))
            band.addLine(to: CGPoint(x: width, y: height - 1))
            band.addQuadCurve(to: CGPoint(x: 0, y: height - 1), control: CGPoint(x: width / 2, y: height + 2.4))
            band.closeSubpath()
            context.saveGState()
            context.addPath(band)
            context.clip()
            // Polished rose gold (round 12): pale lip #FFE3CF, #D9967A
            // body, a slightly deeper waist, and the lower edge lit again
            // (#D9967A → #FFE3CF) instead of a brown band.
            let vertical = [
                JarPalette.color(hex: "#FFE3CF").cgColor,
                JarPalette.color(hex: "#D9967A").cgColor,
                JarPalette.color(hex: "#C98468").cgColor,
                JarPalette.color(hex: "#D9967A").cgColor,
                JarPalette.color(hex: "#FFE3CF").cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: vertical, locations: [0, 0.30, 0.52, 0.78, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 0, y: height + 2),
                    options: []
                )
            }
            // White specular bands: at 30 % of the height (under the mouth's
            // rim on screen) and a second one at 62 %, below the rim where
            // it shows; each a 2 pt white core (α0.95) with soft edges.
            let bandColors = [
                UIColor.white.withAlphaComponent(0).cgColor,
                UIColor.white.withAlphaComponent(0.95).cgColor,
                UIColor.white.withAlphaComponent(0.95).cgColor,
                UIColor.white.withAlphaComponent(0).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: bandColors, locations: [0, 0.3, 0.7, 1]) {
                for bandY in [height * 0.30, height * 0.62] {
                    context.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: 0, y: bandY - 1.7),
                        end: CGPoint(x: 0, y: bandY + 1.7),
                        options: []
                    )
                }
            }
            // Horizontal shading: the band turns away at both ends (a
            // rose shade, never brown).
            let ends = [
                base.withAlphaComponent(0.55).cgColor,
                UIColor.clear.cgColor,
                UIColor.clear.cgColor,
                base.withAlphaComponent(0.65).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: ends, locations: [0, 0.16, 0.84, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: width, y: 0),
                    options: []
                )
            }
            // Anisotropic highlight streaks; tilt slides them.
            let shift = CGFloat(tilt) * 0.07
            for (center, streakWidth, alpha) in [
                (0.20 + shift, 0.07, CGFloat(0.95)),
                (0.34 + shift, 0.025, CGFloat(0.6)),
                (0.80 + shift, 0.05, CGFloat(0.75))
            ] {
                let streak = [
                    UIColor.clear.cgColor,
                    GemColor(highlight).mixed(with: .white, amount: 0.5).withAlpha(alpha).cgColor,
                    UIColor.clear.cgColor
                ] as CFArray
                if let gradient = CGGradient(colorsSpace: space, colors: streak, locations: [0, 0.5, 1]) {
                    context.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: width * (center - streakWidth), y: 0),
                        end: CGPoint(x: width * (center + streakWidth), y: 0),
                        options: []
                    )
                }
            }
            // Engraved milestone marks on the lower edge.
            if marks > 0 {
                let spacing: CGFloat = 5
                let start = width / 2 - spacing * CGFloat(marks - 1) / 2
                for index in 0 ..< marks {
                    let x = start + spacing * CGFloat(index)
                    context.setStrokeColor(shade.withAlphaComponent(0.95).cgColor)
                    context.setLineWidth(1)
                    context.move(to: CGPoint(x: x, y: height - 5.5))
                    context.addLine(to: CGPoint(x: x, y: height - 1.5))
                    context.strokePath()
                    context.setStrokeColor(highlight.withAlphaComponent(0.8).cgColor)
                    context.setLineWidth(0.5)
                    context.move(to: CGPoint(x: x + 0.8, y: height - 5.5))
                    context.addLine(to: CGPoint(x: x + 0.8, y: height - 1.5))
                    context.strokePath()
                }
            }
            context.restoreGState()
            // Bright lip and dark lower edge.
            context.setStrokeColor(GemColor(highlight).mixed(with: .white, amount: 0.4).withAlpha(0.9).cgColor)
            context.setLineWidth(0.8)
            context.move(to: CGPoint(x: 1.5, y: 1.9))
            context.addQuadCurve(to: CGPoint(x: width - 1.5, y: 1.9), control: CGPoint(x: width / 2, y: 3.6))
            context.strokePath()
            context.setStrokeColor(base.withAlphaComponent(0.7).cgColor)
            context.move(to: CGPoint(x: 1.5, y: height - 1))
            context.addQuadCurve(to: CGPoint(x: width - 1.5, y: height - 1), control: CGPoint(x: width / 2, y: height + 2.2))
            context.strokePath()
        }
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        collarTextureCache.setObject(texture, forKey: key)
        return texture
    }

    private func rebuildCollar() {
        guard size.width > .zero, size.height > .zero else { return }
        requestRedraw()
        let outer = outerJarRect
        let mouthWidth = outer.width - neckInset * 2
        let width = mouthWidth + 8
        let height: CGFloat = 17
        collarNode.position = CGPoint(x: outer.midX, y: outer.maxY - 9.5)
        collarNode.zPosition = JarZPosition.glass + 1.1
        for (node, tilt) in [(collarLeftNode, -1), (collarCenterNode, 0), (collarRightNode, 1)] {
            node.texture = Self.collarTexture(width: width, tilt: tilt, marks: milestoneTraceCount)
            node.size = CGSize(width: width, height: height)
            // Two states cross-fade: keep their former child order explicit
            // now that the view ignores sibling order.
            node.zPosition = CGFloat(tilt + 1) * 0.01
        }
        updateCollarTilt(opticalTiltFraction)
    }

    /// Crossfades the three pre-rendered collar states; never more than two
    /// are drawn.
    private func updateCollarTilt(_ fraction: CGFloat) {
        let amount = min(abs(fraction), 1)
        collarCenterNode.alpha = 1 - amount
        collarLeftNode.alpha = fraction < 0 ? amount : 0
        collarRightNode.alpha = fraction > 0 ? amount : 0
        for node in [collarCenterNode, collarLeftNode, collarRightNode] {
            node.isHidden = node.alpha <= 0.001
        }
    }

    private func addStaticEdge(
        from start: CGPoint,
        to end: CGPoint,
        category: UInt32,
        parent: SKNode
    ) {
        let node = SKNode()
        let body = SKPhysicsBody(edgeFrom: start, to: end)
        body.friction = Constants.Jar.friction
        body.restitution = Constants.Jar.restitution
        body.categoryBitMask = category
        body.collisionBitMask = JarPhysicsCategory.pebble
        body.contactTestBitMask = JarPhysicsCategory.pebble
        node.physicsBody = body
        parent.addChild(node)
    }

    private func rebuildFloor() {
        floorNode.removeAllChildren()
        addStaticEdge(
            from: CGPoint(x: interiorRect.minX, y: currentFloorY),
            to: CGPoint(x: interiorRect.maxX, y: currentFloorY),
            category: JarPhysicsCategory.floor,
            parent: floorNode
        )
    }

    private func renderBaseLayers(animatedStratumID: UUID? = nil) {
        requestRedraw()
        let previousScale = strataRenderer.compactionScale
        strataRenderer.render(
            strata: visualStrata,
            bedrock: bedrock,
            in: interiorRect,
            showsMonthLabels: showsMonthLabels,
            animatedStratumID: animatedStratumID,
            reduceMotion: reduceMotion
        )
        if previousScale >= 1, strataRenderer.compactionScale < 1 {
            onCapacityEvent?(
                .layersCompacted(
                    layerCount: visualStrata.count,
                    scale: strataRenderer.compactionScale
                )
            )
        }
    }

    @discardableResult
    private func enqueue(
        _ descriptor: PebbleDescriptor,
        delay: TimeInterval,
        origin: DropOrigin = .interior
    ) -> Bool {
        guard acceptedPebbleIDs.insert(descriptor.id).inserted else { return false }
        dropQueue.append(
            QueuedDrop(
                descriptor: descriptor,
                horizontalUnit: origin == .sceneTop ? 0 : CGFloat.random(in: -1 ... 1),
                origin: origin,
                readyUptime: ProcessInfo.processInfo.systemUptime + delay,
                needsSpecialAnticipation: shouldShowSpecialAnticipation(for: descriptor)
            )
        )
        resumeSimulation()
        if !descriptor.isScreenTimeObstacle { reportApproachingCapacity() }
        return true
    }

    private func shouldShowSpecialAnticipation(for descriptor: PebbleDescriptor) -> Bool {
        if descriptor.isAchievement { return true }
        guard rareRewardMode.usesEnhancedPresentation else { return false }
        return presentationKind(for: descriptor) != .normal
    }

    /// Keep retained reward metadata testable without letting a caller that
    /// bypasses Home's projection re-enable the unreleased visual treatment.
    private func presentationKind(for descriptor: PebbleDescriptor) -> PebbleKind {
        RareRewardReleasePolicy.permitsInternalTestOverride(true)
            ? descriptor.kind
            : .normal
    }

    private func processDropQueue() {
        guard !isBakeInProgress, !dropQueue.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard dropQueue[0].readyUptime <= now,
              now - lastSpawnUptime >= Constants.Jar.dropInterval else { return }

        // Once the live chamber reaches capacity, preserve the rest of the
        // queue until the last spawned stone has landed and its reward beat is
        // visible. The following update frame can then bake safely.
        if needsAggregation {
            _ = beginBakeIfNeeded(force: false)
            return
        }

        if !dropQueue[0].descriptor.isScreenTimeObstacle,
           studyPhysicalBodyCount >= Constants.Jar.maxPhysicsBodies {
            if !beginBakeIfNeeded(force: true) {
                if !hasReportedHardLimit {
                    hasReportedHardLimit = true
                    onCapacityEvent?(
                        .hardLimitReached(
                            physicalCount: physicalPebbleCount,
                            queuedDrops: dropQueue.count
                        )
                    )
                }
            }
            return
        }

        if dropQueue[0].needsSpecialAnticipation {
            dropQueue[0].needsSpecialAnticipation = false
            if !reduceMotion,
               shouldShowSpecialAnticipation(for: dropQueue[0].descriptor) {
                dropQueue[0].readyUptime = now + Constants.Jar.goldPreDropDuration
                showSpecialAnticipation(
                    for: dropQueue[0].descriptor,
                    horizontalUnit: dropQueue[0].horizontalUnit
                )
                return
            }
        }

        let next = dropQueue.removeFirst()
        hasReportedHardLimit = false
        spawn(next.descriptor, horizontalUnit: next.horizontalUnit, origin: next.origin)
        lastSpawnUptime = now
        _ = beginBakeIfNeeded(force: false)
    }

    private func spawn(
        _ descriptor: PebbleDescriptor,
        horizontalUnit: CGFloat,
        origin: DropOrigin
    ) {
        // D4: the incoming gem counts toward the jar's area now and falls at
        // the scale the pile takes when it lands (usually smaller; larger
        // only after the jar itself had to shrink, e.g. under a card).
        let arrivalScale = resolvedJarScale(adding: [descriptor])
        if abs(arrivalScale - jarScale) > 0.0001 {
            scheduledJarScale = arrivalScale
        }
        let node = makePebbleNode(descriptor, studyScale: arrivalScale)
        let xRange = interiorRect.width * Constants.Jar.dropHorizontalRangeFraction
        if origin == .sceneTop {
            let entryRange = allowedHorizontalRange(at: size.height, radius: node.radius)
            node.position = CGPoint(
                x: (entryRange.lowerBound + entryRange.upperBound) / 2,
                y: size.height
            )
            aboveEntryPebbleIDs.insert(descriptor.id)
            // The bottle has a horizontal containment edge across its
            // mouth. Ignore walls only during this centered entry, then
            // rejoin ordinary containment once the whole body is inside.
            node.physicsBody?.categoryBitMask = CompletionEntryPhysics.category
            node.physicsBody?.collisionBitMask &= ~JarPhysicsCategory.wall
            node.physicsBody?.contactTestBitMask &= ~JarPhysicsCategory.wall
        } else {
            node.position = CGPoint(
                x: interiorRect.midX + min(max(horizontalUnit, -1), 1) * xRange,
                y: interiorRect.maxY - node.radius
            )
        }
        node.physicsBody?.velocity = CGVector(
            dx: origin == .sceneTop ? 0 : CGFloat.random(
                in: -Constants.Jar.dropHorizontalSpeed ... Constants.Jar.dropHorizontalSpeed
            ),
            dy: Constants.Jar.dropVerticalSpeed
        )
        node.physicsBody?.angularVelocity = CGFloat.random(
            in: -Constants.Jar.dropHorizontalSpeed ... Constants.Jar.dropHorizontalSpeed
        )
        insertPebble(node)
        if origin == .sceneTop {
            completionDropSequence &+= 1
            completionDropMaximumFall = 0
            completionDropHasLanded = node.hasLanded
            completionDropTracking = node.hasLanded ? nil : CompletionDropTracking(
                pebbleID: descriptor.id,
                startY: node.position.y
            )
        }
        publishPhysicalContentChangeIfNeeded()
        resetIdleObservation()
    }

    private func updateCompletionDropTrackingIfNeeded() {
        guard let tracking = completionDropTracking,
              let pebble = livePebbles.first(where: {
                  $0.descriptor.id == tracking.pebbleID
              })
        else { return }
        completionDropMaximumFall = max(
            completionDropMaximumFall,
            tracking.startY - pebble.position.y
        )
        if pebble.hasLanded {
            completionDropHasLanded = true
            completionDropTracking = nil
        }
    }

    private func finishCompletionEntryPhysics(for pebble: PebbleNode) {
        guard let body = pebble.physicsBody,
              body.categoryBitMask == CompletionEntryPhysics.category
        else { return }
        body.categoryBitMask = JarPhysicsCategory.pebble
        body.collisionBitMask |= JarPhysicsCategory.wall
        body.contactTestBitMask |= JarPhysicsCategory.wall
    }

    @discardableResult
    private func beginBakeIfNeeded(force: Bool) -> Bool {
        guard !isBakeInProgress else { return true }
        let persistenceHandler: (JarBakeRequest) -> Void
        if let onAggregateRequested {
            persistenceHandler = onAggregateRequested
        } else if let onBakeRequested {
            persistenceHandler = onBakeRequested
        } else {
            // Never begin a destructive visual transaction without an owner
            // capable of persisting it.
            return false
        }
        // Fusion is a study-history operation, not a consequence of a random
        // SpriteKit resting position. Stable chronology and UUID ordering make
        // the same ten sources fuse on every device and after every relaunch.
        let pebbles = bakeEligiblePebbles.sorted {
            if $0.descriptor.createdAt == $1.descriptor.createdAt {
                return $0.descriptor.id.uuidString < $1.descriptor.id.uuidString
            }
            return $0.descriptor.createdAt < $1.descriptor.createdAt
        }
        guard pebbles.allSatisfy(\.hasLanded),
              let selected = aggregationSelection(from: pebbles, force: force),
              let request = JarAggregateRequest(
            pebbles: selected.map(\.descriptor),
            innerWidth: interiorRect.width
              )
        else { return false }
        guard !suspendedAggregateIDs.contains(request.id) else { return false }

        let center = selected.reduce(CGPoint.zero) { partial, pebble in
            CGPoint(x: partial.x + pebble.position.x, y: partial.y + pebble.position.y)
        }
        let formationPoint = CGPoint(
            x: center.x / CGFloat(selected.count),
            y: center.y / CGFloat(selected.count)
        )

        isBakeInProgress = true
        hasReportedHardLimit = false
        let bakeToken = UUID()
        activeBake = ActiveBake(
            token: bakeToken,
            request: request,
            sourceNodes: selected,
            formationPoint: formationPoint,
            persistenceHandler: persistenceHandler
        )
        selected.forEach { $0.markForBake() }
        publishPhysicalContentChangeIfNeeded()
        onCapacityEvent?(.bakeStarted(request))

        if reduceMotion {
            completeActiveBake(token: bakeToken)
        } else {
            // 標準 0.52 s; 控えめ converges in 0.32 s (D17).
            let formation = effects.fusion.formation
            // Round 12: the core's labels step aside while the ten meet
            // and their crystal flashes (formation + about 0.4 s).
            isFusionSpotlightActive = true
            selected.forEach { pebble in
                // The ten stay solid and brighten as they meet (additive
                // light and a short trail); only the last 28 % fades, as
                // the crystal takes their place.
                pebble.run(
                    .group([
                        .sequence([
                            .wait(forDuration: formation * 0.72),
                            .fadeOut(withDuration: formation * 0.28)
                        ]),
                        .move(to: formationPoint, duration: formation),
                        .scale(
                            to: Constants.Jar.bakePebbleFinalScale * pebble.xScale,
                            duration: formation
                        )
                    ])
                )
                addConvergenceLight(to: pebble, toward: formationPoint, duration: formation)
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + formation
            ) { [weak self] in
                self?.completeActiveBake(token: bakeToken)
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + formation + Self.fusionSpotlightTail
            ) { [weak self] in
                self?.isFusionSpotlightActive = false
            }
        }
        return true
    }

    /// How long the core's labels stay aside after the ten have met.
    static let fusionSpotlightTail: TimeInterval = 0.4

    /// A converging gem's own light (round 12): an additive halo in its
    /// glint colour that swells over the first 60 % of the formation
    /// (+0.15 L or so on the gem), and a trail about 0.12 s of travel long
    /// behind it. Children of the gem, so they leave with it.
    private func addConvergenceLight(to pebble: PebbleNode, toward point: CGPoint, duration: TimeInterval) {
        guard Self.allowsAmbientSparkle, duration > 0 else { return }
        let tint = GemTone(hex: pebble.descriptor.colorHex, muted: !pebble.descriptor.isMeasured, glass: false)
            .glintUIColor
        let radius = pebble.localRadius
        let halo = SKSpriteNode(texture: GemArtwork.haloTexture, size: CGSize(width: radius * 2.8, height: radius * 2.8))
        halo.name = "drop.fusionConverge"
        halo.color = tint
        halo.colorBlendFactor = 1
        halo.blendMode = .add
        halo.alpha = 0
        halo.zPosition = 2
        pebble.addChild(halo)
        halo.run(.fadeAlpha(to: 0.62 * effects.haloScale, duration: duration * 0.6))

        let dx = point.x - pebble.position.x
        let dy = point.y - pebble.position.y
        let distance = hypot(dx, dy)
        guard distance > radius else { return }
        // In the gem's own (scaled, rotated) frame.
        let scale = max(pebble.xScale, 0.0001)
        let length = min(distance / scale * 0.12 / duration, radius * 3)
        let trail = SKSpriteNode(texture: GemArtwork.haloTexture, size: CGSize(width: length + radius, height: radius * 0.9))
        trail.name = "drop.fusionTrail"
        trail.anchorPoint = CGPoint(x: 1, y: 0.5)
        trail.position = .zero
        trail.zRotation = atan2(dy, dx) - pebble.zRotation
        trail.color = tint
        trail.colorBlendFactor = 1
        trail.blendMode = .add
        trail.alpha = 0
        trail.zPosition = 1.5
        pebble.addChild(trail)
        trail.run(.fadeAlpha(to: 0.5 * effects.haloScale, duration: 0.12))
    }

    /// Commits exactly the aggregation transaction captured before source nodes
    /// were removed from physics. The normal deadline and a mid-animation
    /// Reduce Motion change share this token-guarded completion path.
    private func completeActiveBake(token: UUID) {
        guard let activeBake, activeBake.token == token else { return }
        let request = activeBake.request
        let formationPoint = activeBake.formationPoint
        activeBake.sourceNodes.forEach { source in
            source.removeAllActions()
            source.removeFromParent()
        }

        let descriptor = request.outputDescriptor
        let needsCrystal = !livePebbles.contains(where: { $0.descriptor.id == descriptor.id })
        // D4: ten bodies became one, so A0 fell and the pile may grow back
        // (fusion adds; it never empties the jar). The crystal is born at
        // the new scale while its neighbours grow toward it.
        let fusedScale = resolvedJarScale(adding: needsCrystal ? [descriptor] : [])
        if needsCrystal {
            _ = acceptedPebbleIDs.insert(descriptor.id)
            let aggregateNode = makePebbleNode(descriptor, studyScale: fusedScale)
            aggregateNode.position = CGPoint(
                x: min(
                    max(
                        formationPoint.x,
                        interiorRect.minX + aggregateNode.radius
                    ),
                    interiorRect.maxX - aggregateNode.radius
                ),
                y: min(
                    max(
                        formationPoint.y,
                        currentFloorY + aggregateNode.radius
                    ),
                    interiorRect.maxY - aggregateNode.radius
                )
            )
            aggregateNode.setScale(0.38 * aggregateNode.jarScale)
            aggregateNode.alpha = 0.25
            aggregateNode.physicsBody?.velocity = CGVector(
                dx: 0,
                dy: Constants.Jar.aggregateBirthImpulse
            )
            insertPebble(aggregateNode)
            presentFusionFinale(for: aggregateNode)
        }
        applyJarScale(fusedScale, animated: true)
        refreshPileLight()
        publishPhysicalContentChangeIfNeeded()
        let persistenceHandler = activeBake.persistenceHandler
        self.activeBake = nil
        isBakeInProgress = false
        persistenceHandler(request)
        onCapacityEvent?(.bakeCompleted(request))
        resetIdleObservation()
        resumeSimulation()
    }

    private var needsAggregation: Bool {
        let countsByLevel = Dictionary(grouping: bakeEligiblePebbles) {
            $0.descriptor.aggregateLevel
        }
        // Every complete decimal group is a meaningful progress beat. Waiting
        // for physical capacity made the first ×10 crystal appear only after
        // roughly 120 normal sessions, hiding early progress for weeks.
        return countsByLevel.contains {
            StrataMath.shouldRollUpAggregateLevel(count: $0.value.count)
        }
    }

    private func aggregationSelection(
        from pebbles: [PebbleNode],
        force _: Bool
    ) -> [PebbleNode]? {
        let groups = Dictionary(grouping: pebbles) { $0.descriptor.aggregateLevel }
        let rollUpLevel = groups.keys
            .filter { (groups[$0]?.count ?? 0) >= Constants.Jar.aggregateFanIn }
            .min()
        if let rollUpLevel, let candidates = groups[rollUpLevel] {
            return Array(candidates.prefix(Constants.Jar.aggregateFanIn))
        }
        return nil
    }

    private func cancelActiveBakeForRestore() {
        guard let activeBake else { return }
        self.activeBake = nil
        isBakeInProgress = false
        hasReportedHardLimit = false
        _ = activeBake
    }

    private func reportApproachingCapacity() {
        let queuedRadii = dropQueue
            .filter(\.descriptor.participatesInBake)
            .map { Double($0.descriptor.radius) }
        let units = StrataMath.capacityUnits(
            pebbleRadii: bakeEligibleRadii + queuedRadii
        )
        let occupancyPercent = min(
            100,
            max(0, Int((units / Constants.Jar.bakeCapacityUnits * 100).rounded(.down)))
        )
        let remainingPercent = max(0, 100 - occupancyPercent)
        guard remainingPercent > 0 else { return }
        onCapacityEvent?(
            .approachingBake(
                physicalCount: physicalPebbleCount,
                occupancyPercent: occupancyPercent,
                remainingPercent: remainingPercent
            )
        )
    }

    private func deliverLandingFeedback(
        for pebble: PebbleNode,
        speed: CGFloat,
        point: CGPoint
    ) {
        // These are intentionally adjacent: sound, haptic and particles begin in the same
        // SpriteKit contact callback/frame even when one output has been disabled.
        soundSynth.playThud(impactSpeed: speed)
        haptics.playLanding(impactSpeed: speed)
        if pebble.gemRung != nil, !pebble.descriptor.isTutorial {
            spawnLandingLight(at: point, pebble: pebble)
        } else {
            spawnDust(at: point, color: pebble.subjectColor)
        }
        shakeCamera(impactSpeed: speed)

        switch presentationKind(for: pebble.descriptor) {
        case .normal:
            if pebble.descriptor.isAchievement {
                soundSynth.playGold()
                haptics.playGold()
                spawnSparks(at: point, color: JarPalette.goldHighlight, mark: "✦")
            }
        case .gold:
            if rareRewardMode.usesEnhancedPresentation {
                soundSynth.playGold()
                haptics.playGold()
                spawnSparks(at: point, color: JarPalette.gold, mark: "✦")
            }
        case .prism:
            if rareRewardMode.usesEnhancedPresentation {
                soundSynth.playPrism()
                haptics.playPrism()
                spawnSparks(at: point, color: .white, mark: "◇")
            }
        }
        // Aggregate formation already has one completion event/toast. Its
        // physical landing keeps sound, haptics and dust but must not masquerade
        // as a newly earned study session at the feature boundary.
        if !pebble.descriptor.isAggregate && !pebble.descriptor.isScreenTimeObstacle {
            onLanding?(
                JarLandingEvent(
                    pebble: pebble.descriptor,
                    impactSpeed: speed,
                    position: point
                )
            )
        }
        resetIdleObservation()
    }

    private func playSensoryFeedback(
        trigger: JarSensoryTrigger,
        samples: [JarSensorySample],
        strength: Double,
        userInitiated: Bool
    ) {
        sensorySequence &+= 1
        let plan = JarSensoryPolicy.plan(
            trigger: trigger,
            samples: samples,
            gestureStrength: strength,
            abundanceCount: physicalPebbleCount,
            seed: sensorySequence
        )
        soundSynth.playClinks(plan.clinks, userInitiated: userInitiated)
        haptics.playJarFeedback(plan)

        guard userInitiated else { return }
        interactionCollisionBudget.begin(
            uptime: ProcessInfo.processInfo.systemUptime,
            muteDuration: Constants.Jar.interactionCollisionMuteDuration,
            followUpDuration: Constants.Jar.interactionCollisionFollowUpDuration,
            soundLimit: Constants.Jar.interactionCollisionMaximumSounds,
            hapticLimit: Constants.Jar.interactionCollisionMaximumHaptics
        )
    }

    private func secondaryFeedback(
        for contact: SKPhysicsContact,
        pebbles: [PebbleNode]
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard interactionCollisionBudget.isOpen(uptime: now) else { return }

        let velocities = pebbles.compactMap { $0.physicsBody?.velocity }
        let relativeSpeed: CGFloat
        if velocities.count >= 2 {
            relativeSpeed = hypot(
                velocities[0].dx - velocities[1].dx,
                velocities[0].dy - velocities[1].dy
            )
        } else if let velocity = velocities.first {
            relativeSpeed = hypot(velocity.dx, velocity.dy)
        } else {
            relativeSpeed = 0
        }
        let impulseSpeed = pebbles.compactMap { pebble -> CGFloat? in
            guard let mass = pebble.physicsBody?.mass, mass.isFinite, mass > 0 else {
                return nil
            }
            return contact.collisionImpulse / CGFloat(mass)
        }.max() ?? 0
        let impactSpeed = max(relativeSpeed, impulseSpeed)
        guard impactSpeed.isFinite,
              impactSpeed >= Constants.Sound.gemMinimumCollisionSpeed
        else { return }

        sensorySequence &+= 1
        let plan = JarSensoryPolicy.plan(
            trigger: .collision,
            samples: pebbles.map {
                JarSensorySample(radius: Double($0.sensoryRadius), coupling: 1)
            },
            gestureStrength: Double(min(max(impactSpeed / 8, 0.08), 1)),
            abundanceCount: physicalPebbleCount,
            seed: sensorySequence
        )
        let decision = interactionCollisionBudget.consume(
            uptime: now,
            soundReady: now - lastSecondarySoundUptime >= plan.soundCooldown,
            hapticReady: now - lastSecondaryHapticUptime >= plan.hapticCooldown
        )
        if decision.playSound {
            lastSecondarySoundUptime = now
            soundSynth.playClinks(plan.clinks, userInitiated: false)
        }
        if decision.playHaptic {
            lastSecondaryHapticUptime = now
            haptics.playJarFeedback(plan)
        }
    }

    private func spawnDust(at point: CGPoint, color: UIColor) {
        guard !reduceMotion else { return }
        let beat = effects.landing
        let count = beat.sparkCount(standard: Constants.Jar.dustCount)
        let lifetime = Constants.Jar.dustLifetime * beat.particleLifetimeScale
        for index in 0..<count {
            let angle = CGFloat(index) / CGFloat(max(count, 1)) * .pi
            let particle = SKShapeNode(
                circleOfRadius: Constants.Jar.measuredRadius * Constants.Jar.dustRadiusScale
            )
            particle.name = "drop.dust"
            particle.fillColor = color.withAlphaComponent(Constants.Jar.dustOpacity)
            particle.strokeColor = .clear
            particle.position = point
            particle.zPosition = JarZPosition.effect
            worldNode.addChild(particle)

            let distance = Constants.Jar.measuredRadius * (
                Constants.Jar.dustDistanceBase
                    + CGFloat(index % 3) * Constants.Jar.dustDistanceStep
            ) * beat.particleReach
            let destination = CGPoint(
                x: cos(angle) * distance,
                y: sin(angle) * distance
                    + Constants.Jar.measuredRadius * Constants.Jar.dustVerticalScale
            )
            particle.run(
                .sequence([
                    .group([
                        .moveBy(
                            x: destination.x,
                            y: destination.y,
                            duration: lifetime
                        ),
                        .fadeOut(withDuration: lifetime),
                        .scale(
                            to: Constants.Jar.dustFinalScale,
                            duration: lifetime
                        )
                    ]),
                    .removeFromParent()
                ])
            )
        }
    }

    private func spawnSparks(at point: CGPoint, color: UIColor, mark: String) {
        guard !reduceMotion else { return }
        let beat = effects.landing
        let count = beat.sparkCount(standard: Constants.Jar.goldSparkCount)
        let lifetime = Constants.Jar.goldPreDropDuration * beat.particleLifetimeScale
        for index in 0..<count {
            let angle = CGFloat(index) / CGFloat(max(count, 1)) * .pi * 2
            let spark = SKLabelNode(fontNamed: "HiraginoSans-W6")
            spark.name = "drop.spark"
            spark.text = mark
            spark.fontSize = Constants.Jar.measuredRadius * Constants.Jar.sparkFontScale
            spark.fontColor = color
            spark.position = point
            spark.zPosition = JarZPosition.effect
            worldNode.addChild(spark)
            let distance = Constants.Jar.touchRadius * Constants.Jar.sparkDistanceScale
                * beat.particleReach
            spark.run(
                .sequence([
                    .group([
                        .moveBy(
                            x: cos(angle) * distance,
                            y: sin(angle) * distance,
                            duration: lifetime
                        ),
                        .fadeOut(withDuration: lifetime),
                        .scale(
                            to: Constants.Jar.sparkFinalScale,
                            duration: lifetime
                        )
                    ]),
                    .removeFromParent()
                ])
            )
        }
    }

    private func showSpecialAnticipation(
        for descriptor: PebbleDescriptor,
        horizontalUnit: CGFloat
    ) {
        guard !reduceMotion,
              descriptor.isAchievement || rareRewardMode.usesEnhancedPresentation
        else { return }
        let effectName = descriptor.isAchievement
            ? "drop.anticipation"
            : "drop.anticipation.rare"
        let color: UIColor
        if descriptor.isAchievement {
            color = JarPalette.goldHighlight
        } else {
            switch presentationKind(for: descriptor) {
            case .normal: return
            case .gold: color = JarPalette.gold
            case .prism: color = .white
            }
        }
        let xRange = interiorRect.width * Constants.Jar.dropHorizontalRangeFraction
        let destination = CGPoint(
            x: interiorRect.midX + min(max(horizontalUnit, -1), 1) * xRange,
            y: interiorRect.maxY
        )
        let herald = SKLabelNode(fontNamed: "AvenirNext-Bold")
        herald.name = effectName
        herald.text = presentationKind(for: descriptor) == .prism ? "◇" : "✦"
        herald.fontSize = Constants.Jar.measuredRadius * 1.15
        herald.fontColor = color
        herald.alpha = 0.24
        herald.setScale(0.45)
        herald.position = destination
        herald.zPosition = JarZPosition.effect
        worldNode.addChild(herald)
        herald.run(
            .sequence([
                .group([
                    .fadeAlpha(to: 0.92, duration: Constants.Jar.goldPreDropDuration * 0.55),
                    .scale(to: 1.08, duration: Constants.Jar.goldPreDropDuration)
                ]),
                .removeFromParent()
            ])
        )

        for index in 0..<Constants.Jar.goldSparkCount {
            let angle = CGFloat(index) / CGFloat(max(Constants.Jar.goldSparkCount, 1)) * .pi * 2
            let start = CGPoint(
                x: destination.x + cos(angle) * Constants.Jar.touchRadius,
                y: destination.y + sin(angle) * Constants.Jar.touchRadius
            )
            let mote = SKShapeNode(
                circleOfRadius: Constants.Jar.measuredRadius * Constants.Jar.moteRadiusScale
            )
            mote.name = effectName
            mote.fillColor = color
            mote.strokeColor = .clear
            mote.glowWidth = Constants.Jar.measuredRadius * Constants.Jar.moteGlowScale
            mote.position = start
            mote.zPosition = JarZPosition.effect
            worldNode.addChild(mote)
            mote.run(
                .sequence([
                    .group([
                        .move(to: destination, duration: Constants.Jar.goldPreDropDuration),
                        .scale(
                            to: Constants.Jar.sparkFinalScale,
                            duration: Constants.Jar.goldPreDropDuration
                        )
                    ]),
                    .removeFromParent()
                ])
            )
        }
    }

    private func shakeCamera(impactSpeed: CGFloat) {
        guard !reduceMotion else { return }
        let beat = effects.landing
        let amplitude = min(
            Constants.Jar.screenShakeMaxAmplitude,
            Constants.Jar.screenShakeBaseAmplitude + impactSpeed
        ) * beat.cameraShake
        cameraNode.removeAction(forKey: ActionKey.cameraShake)
        cameraNode.position = cameraRestPosition
        let rest = cameraRestPosition
        let shake = SKAction.customAction(withDuration: beat.cameraShakeDuration) {
            [weak cameraNode] _, elapsed in
            let frames = CGFloat(elapsed) * CGFloat(Constants.Jar.targetFramesPerSecond)
            let current = amplitude * pow(Constants.Jar.screenShakeDecay, frames)
            cameraNode?.position = CGPoint(
                x: rest.x + CGFloat.random(in: -current ... current),
                y: rest.y + CGFloat.random(in: -current ... current)
            )
        }
        cameraNode.run(
            .sequence([
                shake,
                .run { [weak cameraNode] in cameraNode?.position = rest }
            ]),
            withKey: ActionKey.cameraShake
        )
    }

    /// Spontaneous flares while the scene is awake: at most three at once,
    /// at least `gemTwinkleInterval` apart, and 2.5 s between flares of one
    /// gem. The pick is a deterministic sequence hash weighted by glint count
    /// (higher rungs own more glints); there is no randomness and no reward
    /// meaning. Off at 控えめ (D17), with Reduce Motion, Low Power Mode and
    /// serious heat.
    private func updateGemTwinkles(now: TimeInterval) {
        guard effects.allowsSpontaneousTwinkle,
              Self.allowsAmbientSparkle,
              abs(now - lastGemTwinkleCheck) >= 0.15
        else { return }
        lastGemTwinkleCheck = now
        guard abs(now - lastGemTwinkleUptime) >= Constants.Jar.gemTwinkleInterval else { return }
        var candidates: [PebbleNode] = []
        var totalWeight = 0
        var activeCount = 0
        for case let pebble as PebbleNode in worldNode.children where pebble.canGemTwinkle {
            if pebble.isGemTwinkling {
                activeCount += 1
                continue
            }
            guard pebble.canGemTwinkle(at: now) else { continue }
            candidates.append(pebble)
            totalWeight += pebble.gemTwinkleWeight
        }
        guard activeCount < Constants.Jar.maximumConcurrentGemTwinkles,
              totalWeight > 0
        else { return }
        gemTwinkleSequence &+= 1
        var mixed = gemTwinkleSequence &* 0x9E37_79B9_7F4A_7C15
        mixed ^= mixed >> 29
        mixed &*= 0xBF58_476D_1CE4_E5B9
        mixed ^= mixed >> 32
        var pick = Int(mixed % UInt64(totalWeight))
        for pebble in candidates {
            pick -= pebble.gemTwinkleWeight
            if pick < 0 {
                pebble.playGemTwinkle(sequence: mixed >> 7, at: now)
                lastGemTwinkleUptime = now
                return
            }
        }
    }

    /// Ambient sparkle (flares, event particles) pauses in Low Power Mode and
    /// when the device is hot; static light stays.
    static var allowsAmbientSparkle: Bool {
        let info = ProcessInfo.processInfo
        return !info.isLowPowerModeEnabled
            && info.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    /// Recomputes the light the pile casts into the lower jar and marks the
    /// crystal holding the most grams. O(n), a few times a second while
    /// awake and once when the jar settles.
    ///
    /// Only the resting pile lights the jar: a gem that has not landed yet
    /// (a completion falling from the mouth) or one moving faster than
    /// `pileProfileRestingSpeed` never stretches the light, so a drop no
    /// longer floods the core and the HUD with a haze. The light is also
    /// bounded to a band seated on the floor (at most 0.45 of the jar width
    /// across and 0.45 of the interior high, its centre no higher than the
    /// gem bed's top + 40 pt) and eases to a new shape over 0.4 s.
    private func refreshPileLight(animated: Bool = true) {
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var weight: CGFloat = 0
        var heaviest: PebbleNode?
        var aggregates: [PebbleNode] = []
        var hasUnsettledGem = false
        for pebble in livePebbles where !pebble.isRemovedForBake
            && !pebble.descriptor.isScreenTimeObstacle
            && !pebble.descriptor.isTutorial {
            if pebble.descriptor.isAggregate {
                aggregates.append(pebble)
                if heaviest == nil || pebble.descriptor.grams > heaviest?.descriptor.grams ?? 0 {
                    heaviest = pebble
                }
            }
            guard Self.castsPileLight(pebble) else {
                hasUnsettledGem = true
                continue
            }
            let r = pebble.radius
            minX = min(minX, pebble.position.x - r)
            maxX = max(maxX, pebble.position.x + r)
            minY = min(minY, pebble.position.y - r)
            maxY = max(maxY, pebble.position.y + r)
            let tone = GemTone(hex: pebble.descriptor.colorHex, muted: !pebble.descriptor.isMeasured, glass: false).halo
            let w = r * r
            red += tone.red * w
            green += tone.green * w
            blue += tone.blue * w
            weight += w
        }
        aggregates.forEach { $0.setPileEmphasis($0 === heaviest) }
        guard weight > 0 else {
            // Nothing rests yet (an empty jar, or only a falling gem): keep
            // the last resting light rather than flashing it off mid-drop.
            if !hasUnsettledGem {
                pileGlowNode.removeAction(forKey: ActionKey.pileGlowShape)
                pileGlowNode.alpha = 0
                pileGlowBaseAlpha = 0
            }
            return
        }
        let mean = GemColor(red: red / weight, green: green / weight, blue: blue / weight)
        // Warm-biased (60 % #FF9E6B) so a blue/violet pile still reads as
        // lit rather than foggy.
        let color = mean.mixed(with: GemColor(hex: "#FF9E6B"), amount: 0.6).withAlpha(1)
        let target = Self.pileLightFrame(
            bodies: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            jar: outerJarRect,
            interior: interiorRect,
            bedTop: currentFloorY + (gemBed.map { $0.height(interiorHeight: interiorRect.height) } ?? 0)
        )
        // The lit interior (JarStageArtwork) already glows toward the
        // floor, so the pile adds a softer light than before.
        pileGlowBaseAlpha = 0.45 * (reduceTransparency ? 0.45 : 1)
        if pileGlowNode.action(forKey: "jar.pileGlow.pulse") == nil {
            pileGlowNode.alpha = pileGlowBaseAlpha
        }
        pileGlowNode.removeAction(forKey: ActionKey.pileGlowShape)
        let isFirstLight = pileGlowNode.size.width < 1
        guard animated, !isFirstLight, !isPaused, !reduceMotion else {
            pileGlowNode.color = color
            pileGlowNode.size = target.size
            pileGlowNode.position = CGPoint(x: target.midX, y: target.midY)
            return
        }
        let duration: TimeInterval = 0.4
        let startColor = GemColor(pileGlowNode.color)
        let endColor = GemColor(color)
        let tint = SKAction.customAction(withDuration: duration) { node, elapsed in
            let t = CGFloat(elapsed / duration)
            (node as? SKSpriteNode)?.color = startColor.mixed(with: endColor, amount: t).withAlpha(1)
        }
        let resize = SKAction.resize(toWidth: target.width, height: target.height, duration: duration)
        let move = SKAction.move(to: CGPoint(x: target.midX, y: target.midY), duration: duration)
        [resize, move].forEach { $0.timingMode = .easeInEaseOut }
        pileGlowNode.run(.group([resize, move, tint]), withKey: ActionKey.pileGlowShape)
    }

    /// Whether a body counts toward the pile light: it has landed and rests
    /// (the same speed test as the settled pile profile).
    private static func castsPileLight(_ pebble: PebbleNode) -> Bool {
        guard pebble.hasLanded else { return false }
        if let velocity = pebble.physicsBody?.velocity,
           hypot(velocity.dx, velocity.dy) > pileProfileRestingSpeed {
            return false
        }
        return pebble.position.x.isFinite && pebble.position.y.isFinite
    }

    /// The pile light's rectangle for resting bodies spanning `bodies`:
    /// 1.3 × their width (at least 96 pt, at most 0.9 × the jar width),
    /// 1.8 × their height (at least 64 pt, at most 0.45 of the interior and
    /// 0.75 of its own width), seated on the floor with its centre no higher
    /// than the gem bed's top + 40 pt.
    nonisolated static func pileLightFrame(
        bodies: CGRect,
        jar: CGRect,
        interior: CGRect,
        bedTop: CGFloat
    ) -> CGRect {
        let width = min(max(96, bodies.width * 1.3), jar.width * 0.9)
        let height = min(
            max(64, bodies.height * 1.8),
            width * 0.75,
            interior.height * 0.45
        )
        let floorY = interior.minY
        let centerY = min(
            max(bodies.midY, floorY + height * 0.22),
            max(bedTop, floorY) + 40,
            floorY + height * 0.5
        )
        let centerX = min(max(bodies.midX, jar.minX + width / 2), jar.maxX - width / 2)
        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    private func publishSettledPileTop() {
        let count = Self.pileProfileBinCount
        guard size.width > 0 else { return }
        let binWidth = size.width / CGFloat(count)
        var profile = [CGFloat](repeating: 0, count: count)
        for pebble in livePebbles where !pebble.isRemovedForBake {
            if let velocity = pebble.physicsBody?.velocity,
               hypot(velocity.dx, velocity.dy) > Self.pileProfileRestingSpeed {
                continue
            }
            // A body flung out of range (or a non-finite position) must
            // never trap the Int conversion below.
            guard pebble.position.x.isFinite, pebble.position.y.isFinite else { continue }
            let top = min(max(0, pebble.position.y + pebble.radius), size.height)
            let left = min(max(pebble.position.x - pebble.radius, 0), size.width)
            let right = min(max(pebble.position.x + pebble.radius, 0), size.width)
            let first = max(0, Int(left / binWidth))
            let last = min(count - 1, Int(right / binWidth))
            guard first <= last else { continue }
            for bin in first ... last {
                profile[bin] = max(profile[bin], (top / 4).rounded(.up) * 4)
            }
        }
        if profile != settledPileProfile { settledPileProfile = profile }
    }

    /// Bakes gem bed textures off the main thread (tests may bake inline).
    var bakesGemBedInBackground = true
    /// A background bed bake is running (tests wait for it).
    private(set) var isGemBedBaking = false
    private var gemBedBakeGeneration: UInt64 = 0

    /// Re-bakes (or reuses) the gem bed texture for the current lifetime
    /// state and jar size. Depends on `gemBed`, the interior rect and the
    /// display scale only. A cached texture shows at once; a new one bakes
    /// on a utility queue while the previous bed stays on screen, and the
    /// texture, size and position change together when it is ready.
    private func refreshGemBed() {
        gemBedBakeGeneration &+= 1
        guard size.width > .zero, size.height > .zero,
              let state = gemBed, state.isVisible
        else {
            isGemBedBaking = false
            gemBedNode.isHidden = true
            gemBedNode.texture = nil
            requestRedraw()
            return
        }
        let interior = interiorRect
        let height = state.height(interiorHeight: interior.height)
        guard height >= 2 else {
            isGemBedBaking = false
            gemBedNode.isHidden = true
            gemBedNode.texture = nil
            requestRedraw()
            return
        }
        let width = interior.width.rounded()
        let hexes = state.slotHexes
        let scale = artworkScale
        let install: (SKTexture) -> Void = { [weak self] texture in
            guard let self else { return }
            self.gemBedNode.texture = texture
            self.gemBedNode.size = CGSize(width: width, height: height)
            self.gemBedNode.position = CGPoint(x: interior.midX, y: interior.minY)
            self.gemBedNode.alpha = 1
            self.gemBedNode.isHidden = false
            // The bed may finish baking after the jar has come to rest.
            self.requestRedraw()
        }
        if let cached = GemArtwork.cachedBedTexture(width: width, height: height, slotHexes: hexes, scale: scale) {
            isGemBedBaking = false
            install(cached)
            return
        }
        guard bakesGemBedInBackground else {
            isGemBedBaking = false
            install(GemArtwork.bedTexture(width: width, height: height, slotHexes: hexes, scale: scale))
            return
        }
        isGemBedBaking = true
        let generation = gemBedBakeGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let texture = GemArtwork.bedTexture(width: width, height: height, slotHexes: hexes, scale: scale)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.gemBedBakeGeneration == generation else { return }
                    self.isGemBedBaking = false
                    install(texture)
                }
            }
        }
    }

    /// Landing light: 6–8 soft sparks from the shared glint texture (3–4,
    /// shorter and closer at 控えめ), at most `maximumEventLightSprites`
    /// alive at once, plus a brief pile-light swell. Reduce Motion never
    /// spawns them.
    private func spawnLandingLight(at point: CGPoint, pebble: PebbleNode) {
        guard !reduceMotion, Self.allowsAmbientSparkle else { return }
        pebble.playLandingPulse()
        let beat = effects.landing
        let tint = GemTone(hex: pebble.descriptor.colorHex, muted: !pebble.descriptor.isMeasured, glass: false)
            .glintUIColor
        let count = beat.sparkCount(standard: 6 + Int(pebble.descriptor.id.presentationHash % 3))
        for index in 0 ..< count where eventLightCount < Constants.Jar.maximumEventLightSprites {
            let spark = SKSpriteNode(
                texture: index.isMultiple(of: 3) ? GemArtwork.glintTexture : GemArtwork.haloTexture,
                size: CGSize(width: 7, height: 7)
            )
            spark.name = "drop.light"
            spark.color = tint
            spark.colorBlendFactor = 1
            spark.blendMode = .add
            spark.position = CGPoint(x: point.x, y: point.y + pebble.radius * 0.2)
            spark.zPosition = JarZPosition.effect
            worldNode.addChild(spark)
            eventLightCount += 1
            let angle = CGFloat.pi * (0.15 + 0.7 * CGFloat(index) / CGFloat(max(count - 1, 1)))
            let distance = pebble.radius * (1.3 + CGFloat(index % 3) * 0.45) * beat.particleReach
            let lifetime: TimeInterval = 0.52 * beat.particleLifetimeScale
            let move = SKAction.moveBy(x: cos(angle) * distance, y: sin(angle) * distance, duration: lifetime)
            move.timingMode = .easeOut
            spark.run(.sequence([
                .group([move, .fadeOut(withDuration: lifetime), .scale(to: 0.4, duration: lifetime)]),
                .run { [weak self] in self?.eventLightCount -= 1 },
                .removeFromParent()
            ]))
        }
        guard pileGlowBaseAlpha > 0 else { return }
        let swell = SKAction.sequence([
            .fadeAlpha(to: min(1, pileGlowBaseAlpha * beat.pileSwell), duration: beat.pileSwellRise),
            .fadeAlpha(to: pileGlowBaseAlpha, duration: beat.pileSwellFall)
        ])
        pileGlowNode.run(swell, withKey: "jar.pileGlow.pulse")
    }

    /// Fusion finale by rung (`JarEffectsIntensity.fusion`). 標準: A0 only
    /// fades in (200 ms); A1+ adds a white flash (2.2R, 160 ms), a shock
    /// ring (1R → 3R, 420 ms) and a spring birth (0.6 → 1.08 → 1.0,
    /// 380 ms); A2+ adds twelve shards. 控えめ: a 120 ms fade, a fainter
    /// 100 ms flash, a 1R → 2.2R ring in 260 ms, a 0.85 → 1.0 birth with
    /// no overshoot and no shards. Reduce Motion shows a static ring for
    /// 600 ms and no motion on the stone.
    private func presentFusionFinale(for node: PebbleNode) {
        let tier = GemCutLadder.aggregateTier(grams: node.descriptor.grams)
        let point = node.position
        let rest = node.jarScale
        if reduceMotion {
            node.setScale(rest)
            node.alpha = 1
            guard tier >= 1 else { return }
            let ring = makeFusionRing(at: point, radius: node.radius)
            ring.setScale(2)
            ring.alpha = 0.55
            ring.run(.sequence([.wait(forDuration: 0.6), .removeFromParent()]))
            return
        }
        let beat = effects.fusion
        guard tier >= 1, Self.allowsAmbientSparkle else {
            node.setScale(rest)
            node.alpha = 0
            node.run(.fadeIn(withDuration: beat.fadeIn))
            return
        }
        node.alpha = 1
        node.setScale(beat.birthStart * rest)
        let grow = SKAction.scale(to: beat.birthOvershoot * rest, duration: beat.birthGrow)
        grow.timingMode = .easeOut
        if beat.birthSettle > 0 {
            let settle = SKAction.scale(to: rest, duration: beat.birthSettle)
            settle.timingMode = .easeInEaseOut
            node.run(.sequence([grow, settle]), withKey: PebbleNode.birthActionKey)
        } else {
            node.run(grow, withKey: PebbleNode.birthActionKey)
        }

        let flash = SKSpriteNode(
            texture: GemArtwork.haloTexture,
            size: CGSize(width: node.radius * 4.4, height: node.radius * 4.4)
        )
        flash.name = "drop.fusionFlash"
        flash.color = .white
        flash.colorBlendFactor = 1
        flash.blendMode = .add
        flash.alpha = beat.flashAlpha
        flash.position = point
        flash.zPosition = JarZPosition.effect
        worldNode.addChild(flash)
        flash.run(.sequence([.fadeOut(withDuration: beat.flashDuration), .removeFromParent()]))

        let ring = makeFusionRing(at: point, radius: node.radius)
        let expand = SKAction.scale(to: beat.ringScale, duration: beat.ringDuration)
        expand.timingMode = .easeOut
        ring.run(.sequence([.group([expand, .fadeOut(withDuration: beat.ringDuration)]), .removeFromParent()]))
        presentFusionAfterglow(on: node)

        guard tier >= 2, beat.shardCount > 0 else { return }
        let tint = GemTone(hex: node.descriptor.colorHex, muted: false, glass: false).glintUIColor
        for index in 0 ..< beat.shardCount where eventLightCount < Constants.Jar.maximumEventLightSprites {
            let shard = SKSpriteNode(texture: GemArtwork.glintTexture, size: CGSize(width: 8, height: 8))
            shard.name = "drop.fusionShard"
            shard.color = tint
            shard.colorBlendFactor = 1
            shard.blendMode = .add
            shard.position = point
            shard.zPosition = JarZPosition.effect
            worldNode.addChild(shard)
            eventLightCount += 1
            let angle = CGFloat(index) / CGFloat(beat.shardCount) * .pi * 2
            let distance = node.radius * 2.6
            let move = SKAction.moveBy(x: cos(angle) * distance, y: sin(angle) * distance, duration: beat.shardLifetime)
            move.timingMode = .easeOut
            shard.run(.sequence([
                .group([move, .fadeOut(withDuration: beat.shardLifetime)]),
                .run { [weak self] in self?.eventLightCount -= 1 },
                .removeFromParent()
            ]))
        }
    }

    /// After the flash (round 12): the new crystal keeps a warm afterglow
    /// for 1.2 s and three glints open and close on its crown one after
    /// another (two at 控えめ), so ten gems becoming one reads as a gain,
    /// not as a jar that emptied. Children of the crystal: they ride its
    /// birth bounce and leave with it.
    private func presentFusionAfterglow(on node: PebbleNode) {
        let radius = node.localRadius
        let tint = GemTone(hex: node.descriptor.colorHex, muted: false, glass: false).glintUIColor
        let glow = SKSpriteNode(texture: GemArtwork.haloTexture, size: CGSize(width: radius * 3.4, height: radius * 3.4))
        glow.name = "drop.fusionAfterglow"
        glow.color = tint
        glow.colorBlendFactor = 1
        glow.blendMode = .add
        glow.alpha = 0
        glow.zPosition = 2
        node.addChild(glow)
        let peak = 0.55 * effects.haloScale
        glow.run(.sequence([
            .fadeAlpha(to: peak, duration: 0.15),
            .wait(forDuration: 0.5),
            .fadeOut(withDuration: 0.55),
            .removeFromParent()
        ]))
        let spots: [CGPoint] = [
            CGPoint(x: -0.38, y: 0.42), CGPoint(x: 0.44, y: 0.12), CGPoint(x: -0.06, y: -0.36)
        ]
        let count = effects == .subtle ? 2 : 3
        for (index, spot) in spots.prefix(count).enumerated() {
            let glint = SKSpriteNode(texture: GemArtwork.glintTexture, size: CGSize(width: radius * 0.7, height: radius * 0.7))
            glint.name = "drop.fusionGlint"
            glint.color = .white
            glint.colorBlendFactor = 1
            glint.blendMode = .add
            glint.position = CGPoint(x: spot.x * radius, y: spot.y * radius)
            glint.zPosition = 3
            glint.setScale(0)
            node.addChild(glint)
            let open = SKAction.scale(to: 1, duration: 0.16)
            open.timingMode = .easeOut
            let close = SKAction.scale(to: 0, duration: 0.3)
            close.timingMode = .easeIn
            glint.run(.sequence([
                .wait(forDuration: 0.12 + Double(index) * 0.26),
                open,
                .wait(forDuration: 0.12),
                close,
                .removeFromParent()
            ]))
        }
    }

    private func makeFusionRing(at point: CGPoint, radius: CGFloat) -> SKSpriteNode {
        let ring = SKSpriteNode(
            texture: GemArtwork.ringTexture,
            size: CGSize(width: radius * 2, height: radius * 2)
        )
        ring.name = "drop.fusionRing"
        ring.color = JarPalette.color(hex: "#FFE3B0")
        ring.colorBlendFactor = 1
        ring.blendMode = .add
        ring.position = point
        ring.zPosition = JarZPosition.effect
        worldNode.addChild(ring)
        return ring
    }

    private func updateRareTwinkles() {
        guard effects.allowsSpontaneousTwinkle, rareRewardMode.usesEnhancedPresentation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTwinkleUptime >= Constants.Jar.rareTwinkleInterval else { return }
        lastTwinkleUptime = now
        for pebble in livePebbles {
            let probability: Double
            let mark: String
            let color: UIColor
            switch presentationKind(for: pebble.descriptor) {
            case .normal:
                continue
            case .gold:
                probability = Constants.Jar.goldTwinkleProbability
                mark = "✦"
                color = JarPalette.goldHighlight
            case .prism:
                probability = Constants.Jar.prismTwinkleProbability
                mark = "◇"
                color = .white
            }
            guard Double.random(in: 0 ... 1) < probability else { continue }
            let star = SKLabelNode(fontNamed: "HiraginoSans-W6")
            star.name = "ambient.twinkle"
            star.text = mark
            star.fontSize = pebble.radius * Constants.Jar.twinkleFontScale
            star.fontColor = color
            star.position = pebble.position
            star.zPosition = JarZPosition.effect
            worldNode.addChild(star)
            star.run(
                .sequence([
                    .group([
                        .moveBy(x: 0, y: pebble.radius, duration: Constants.Jar.goldPreDropDuration),
                        .fadeOut(withDuration: Constants.Jar.goldPreDropDuration),
                        .scale(
                            to: Constants.Jar.twinkleFinalScale,
                            duration: Constants.Jar.goldPreDropDuration
                        )
                    ]),
                    .removeFromParent()
                ])
            )
        }
    }

    private func updateIdlePause(
        currentTime: TimeInterval,
        uptime: TimeInterval
    ) {
        // A failed aggregate may leave persisted-but-not-yet-rendered drops in
        // the queue. Let the visible chamber settle and pause while the explicit
        // retry UI is waiting instead of burning frames forever.
        guard (dropQueue.isEmpty || !suspendedAggregateIDs.isEmpty),
              !isBakeInProgress
        else {
            interactionMotionWindow = nil
            resetIdleObservation()
            return
        }

        if let interactionMotionWindow,
           interactionMotionWindow.mustStop(at: uptime) {
            // A scale transition in flight (at most 0.5 s) finishes first:
            // freezing it would snap growing neighbours to full size while
            // they still overlap.
            if isJarScaleTransitionInFlight { return }
            if livePebbles.allSatisfy(\.hasLanded) {
                pauseSettledSimulation()
                return
            }
            // A newly earned gem can already be in the scene while its first
            // landing callback is still pending. Never freeze that semantic
            // transaction in mid-air; retire only the interaction deadline and
            // hand it back to the ordinary landing/idle lifecycle.
            self.interactionMotionWindow = nil
        }
        guard let started = idleSampleStartedAt else {
            idleSampleStartedAt = currentTime
            livePebbles.forEach { $0.rememberObservedPosition() }
            return
        }
        guard currentTime - started >= Constants.Jar.idleWindow else { return }

        if let interactionMotionWindow,
           !interactionMotionWindow.canSettle(at: uptime) {
            return
        }

        // The old sum made a full jar progressively harder to settle: tiny
        // harmless movement from 128 gems could outweigh a quiet single-gem
        // jar. The maximum per-body displacement is independent of body count.
        let movement = livePebbles.reduce(CGFloat.zero) { maximum, pebble in
            max(maximum, hypot(
                pebble.position.x - pebble.lastObservedPosition.x,
                pebble.position.y - pebble.lastObservedPosition.y
            ))
        }
        if movement < Constants.Jar.idleMovementThreshold, !isJarScaleTransitionInFlight {
            pauseSettledSimulation()
        } else {
            let isSettlingInteraction = interactionMotionWindow != nil
            livePebbles.forEach { pebble in
                pebble.physicsBody?.linearDamping = isSettlingInteraction
                    ? Constants.Jar.interactionSettlingDamping
                    : Constants.Jar.linearDamping
                pebble.physicsBody?.angularDamping = isSettlingInteraction
                    ? Constants.Jar.interactionSettlingDamping
                    : Constants.Jar.angularDamping
                pebble.rememberObservedPosition()
            }
            idleSampleStartedAt = currentTime
        }
    }

#if DEBUG
    /// Deterministic clock seam for regression tests. Release builds can only
    /// advance this state from SpriteKit's render loop.
    func evaluateInteractionMotionForTesting(
        currentTime: TimeInterval,
        uptime: TimeInterval
    ) {
        updateIdlePause(currentTime: currentTime, uptime: uptime)
    }
#endif

    /// Whether any live body is still easing to a new jar scale.
    private var isJarScaleTransitionInFlight: Bool {
        livePebbles.contains(where: \.isTransitioningJarScale)
    }

    /// Freezes only presentation physics. Study records, aggregate membership,
    /// mass, and cloud state live outside SpriteKit and are never touched.
    private func pauseSettledSimulation() {
        // A frozen jar never keeps a half-scaled body. The idle and hard
        // stops wait for a transition, so one is cut short only by an
        // explicit pause; its bodies are then put back inside the walls at
        // once (the scheduled rescue would not run until the next wake).
        let cutShort = isJarScaleTransitionInFlight
        livePebbles.forEach { $0.finishJarScaleTransition() }
        if cutShort {
            removeAction(forKey: "jar.scale.rescue")
            rescuePebblesInsideWalls()
        }
        finishActiveTapMotion(forceReturn: false)
        transientMotionGate.invalidate()
        interactionMotionWindow = nil
        interactionCollisionBudget.cancel()
        livePebbles.forEach { pebble in
            guard let body = pebble.physicsBody else { return }
            body.velocity = .zero
            body.angularVelocity = .zero
            body.linearDamping = Constants.Jar.restingDamping
            body.angularDamping = Constants.Jar.restingDamping
            body.usesPreciseCollisionDetection = false
            body.isResting = true
        }
        // The light enters the idle state exactly where gravity is, so the
        // idle gate's small residual can only come from later samples.
        updateOpticalTilt(horizontal: appliedGravityVector.dx)
        // Never freeze a half-lit flare: settle every star to its resting
        // (or tilt-lit) value before the frame stops.
        livePebbles.forEach {
            $0.settleGemTwinkle()
            $0.updatePresentationLighting(horizontal: opticalTiltFraction)
        }
        refreshPileLight(animated: false)
        publishSettledPileTop()
        // A settled pile over the core or the HUD steps down first: the jar
        // stays awake for the 0.5 s transition and settles anew after it.
        if enforcePileClearances() { return }
        if !isIdlePaused {
            isIdlePaused = true
            onIdlePauseChanged?(true)
        }
        isPaused = true
        // The settled frame is drawn, then the render loop stops (jar-01)
        // and device motion drops to its idle rate.
        requestRedraw()
    }

    /// Prepares a deterministic, transparent-safe frame for `JarSnapshotter`:
    /// flares settle, and additive light is drawn as ordinary alpha blending
    /// (additive colour over a clear texture would be lost or saturated when
    /// the PNG is un-premultiplied). Returns the restore closure.
    func prepareForSnapshot() -> () -> Void {
        let pebbles = allPebbleNodes
        pebbles.forEach {
            $0.settleGemTwinkle()
            $0.updatePresentationLighting(horizontal: 0)
            $0.setSnapshotBlending(true)
        }
        // Each light keeps its own original mode for the restore, so a
        // light that is not additive today is never forced to `.add`.
        // Alpha-blended colour over a clear texture reads much stronger
        // than the same light added to the dark jar, so the broad floor and
        // pile lights are halved for the capture (no pink haze).
        let sceneLights = [floorGlowNode, pileGlowNode, glassHighlightNode].map { ($0, $0.blendMode, $0.alpha) }
        sceneLights.forEach { $0.0.blendMode = .alpha }
        floorGlowNode.alpha *= 0.5
        pileGlowNode.alpha *= 0.45
        return { [weak self] in
            pebbles.forEach {
                $0.setSnapshotBlending(false)
                $0.updatePresentationLighting(horizontal: self?.opticalTiltFraction ?? 0)
            }
            sceneLights.forEach {
                $0.0.blendMode = $0.1
                $0.0.alpha = $0.2
            }
            // A resting jar's render loop is stopped: show the restored
            // (settled) frame, so the screen never lags the scene.
            self?.requestRedraw()
        }
    }

    private func resetIdleObservation() {
        idleSampleStartedAt = nil
        livePebbles.forEach {
            $0.physicsBody?.linearDamping = Constants.Jar.linearDamping
            $0.physicsBody?.angularDamping = Constants.Jar.angularDamping
            $0.rememberObservedPosition()
        }
    }

    /// Invalidates SwiftUI only when the live physics chamber transitions to a
    /// different body count, or gains or loses its study gems (they decide
    /// whether device motion runs). `physicalPebbleCount` itself remains
    /// computed from `livePebbles`, avoiding a second, potentially stale
    /// emptiness source.
    private func publishPhysicalContentChangeIfNeeded(force: Bool = false) {
        refreshEarlyEffortSpotlightsIfNeeded()
        let count = physicalPebbleCount
        let hasStudyGems = self.hasStudyGems
        guard force
            || count != lastPublishedPhysicalPebbleCount
            || hasStudyGems != lastPublishedHasStudyGems
        else { return }
        lastPublishedPhysicalPebbleCount = count
        lastPublishedHasStudyGems = hasStudyGems
        physicalContentRevision &+= 1
    }

    /// A 520pt bottle can visually swallow an honest 11.5pt first stone. Keep
    /// one-to-three loose study stones discoverable with a non-colliding aura;
    /// aggregates, achievements and later progress retain their own hierarchy.
    private func refreshEarlyEffortSpotlightsIfNeeded() {
        let studyBodies = livePebbles.filter {
            !$0.isRemovedForBake && $0.descriptor.participatesInAggregation
        }
        let nextIDs: Set<UUID>
        if (1...3).contains(studyBodies.count),
           studyBodies.allSatisfy({ !$0.descriptor.isAggregate }) {
            nextIDs = Set(studyBodies.map(\.descriptor.id))
        } else {
            nextIDs = []
        }
        guard nextIDs != earlyEffortSpotlightIDs else { return }
        earlyEffortSpotlightIDs = nextIDs
        livePebbles.forEach {
            $0.setEarlyEffortSpotlight(nextIDs.contains($0.descriptor.id))
        }
    }

    private func rescuePebblesInsideWalls() {
        for pebble in livePebbles {
            let horizontalRange = allowedHorizontalRange(
                at: pebble.position.y,
                radius: pebble.radius
            )
            pebble.position.x = min(
                max(pebble.position.x, horizontalRange.lowerBound),
                horizontalRange.upperBound
            )
            let previousY = pebble.position.y
            let upperY = aboveEntryPebbleIDs.contains(pebble.descriptor.id) && !pebble.hasLanded
                ? size.height
                : interiorRect.maxY - pebble.radius
            pebble.position.y = min(pebble.position.y, upperY)
            if completionDropTracking?.pebbleID == pebble.descriptor.id {
                // A geometry rescue is layout, not observed physical travel.
                completionDropTracking?.startY += pebble.position.y - previousY
            }
        }
        rescuePebblesBelowFloor()
    }

    private func allowedHorizontalRange(
        at verticalPosition: CGFloat,
        radius: CGFloat
    ) -> ClosedRange<CGFloat> {
        let shoulderTravel = max(neckBaseY - shoulderStartY, 1)
        let shoulderFraction = min(
            max((verticalPosition - shoulderStartY) / shoulderTravel, 0),
            1
        )
        let leftInset = (neckInteriorMinX - interiorRect.minX) * shoulderFraction
        let rightInset = (interiorRect.maxX - neckInteriorMaxX) * shoulderFraction
        let lower = interiorRect.minX + leftInset + radius
        let upper = interiorRect.maxX - rightInset - radius
        if lower <= upper { return lower ... upper }
        let center = interiorRect.midX
        return center ... center
    }

    private func rescuePebblesBelowFloor() {
        for pebble in livePebbles where pebble.position.y - pebble.radius < currentFloorY {
            pebble.position.y = currentFloorY + pebble.radius
            pebble.physicsBody?.velocity.dy = max(pebble.physicsBody?.velocity.dy ?? .zero, .zero)
        }
    }
}

/// Wall-clock policy for a deliberate physics interaction. SpriteKit's scene
/// time stops while paused, so monotonic uptime keeps the maximum duration
/// truthful across frame drops without scheduling stale callbacks.
struct JarInteractionMotionWindow: Equatable {
    let openedAt: TimeInterval
    let settleAt: TimeInterval
    let hardStopAt: TimeInterval

    init(
        openedAt: TimeInterval,
        settleDelay: TimeInterval = Constants.Jar.idleWindow,
        hardStopDelay: TimeInterval = Constants.Jar.interactionHardStopDelay
    ) {
        let safeOpenedAt = openedAt.isFinite ? openedAt : 0
        let safeSettleDelay = settleDelay.isFinite ? max(0, settleDelay) : 0
        let safeHardStopDelay = hardStopDelay.isFinite
            ? max(safeSettleDelay, hardStopDelay)
            : safeSettleDelay
        self.openedAt = safeOpenedAt
        settleAt = safeOpenedAt + safeSettleDelay
        hardStopAt = safeOpenedAt + safeHardStopDelay
    }

    func canSettle(at uptime: TimeInterval) -> Bool {
        uptime.isFinite && uptime >= settleAt
    }

    func mustStop(at uptime: TimeInterval) -> Bool {
        uptime.isFinite && uptime >= hardStopAt
    }
}

/// Invalidates delayed tap work without relying on cancellation timing from
/// `DispatchQueue`. A later interaction or lifecycle cancellation ends the tap
/// generation synchronously before either can mutate body state.
struct JarTransientMotionGate {
    private(set) var generation: UInt64 = 0
    private(set) var isActive = false

    mutating func begin() -> UInt64 {
        generation &+= 1
        isActive = true
        return generation
    }

    mutating func invalidate() {
        isActive = false
        generation &+= 1
    }

    func accepts(_ candidate: UInt64) -> Bool {
        isActive && generation == candidate
    }
}

struct JarTapLaunchPlan: Equatable {
    let targetTravel: CGFloat
    let verticalVelocity: CGFloat
    let horizontalVelocity: CGFloat
    let returnVelocity: CGFloat
}

/// Radius-aware launch tuning for the directly tapped gem. A normal 23-point
/// gem targets about 69 points of travel (three diameters), while larger
/// aggregate gems are capped so their visual weight remains believable and a
/// single interaction cannot cross most of the bottle.
enum JarTapLaunchPolicy {
    static let targetDiameterMultiplier: CGFloat = 3
    static let maximumTargetTravel: CGFloat = 96
    static let maximumVerticalVelocity: CGFloat = 320
    static let maximumHorizontalVelocity: CGFloat = 160
    static let flightDuration: TimeInterval = 0.38

    private static let minimumStrengthScale: CGFloat = 0.82
    // Calibrated against SpriteKit's real floor-contact solver rather than a
    // frictionless ballistic equation. The extra launch energy is bounded by
    // the explicit component ceilings below.
    private static let horizontalTravelFraction: CGFloat = 0.80
    private static let estimatedVelocityRetention: CGFloat = 0.58

    static func plan(
        radius proposedRadius: CGFloat,
        strength proposedStrength: CGFloat,
        upwardRoom proposedUpwardRoom: CGFloat
    ) -> JarTapLaunchPlan {
        let radius = proposedRadius.isFinite ? max(0, proposedRadius) : 0
        let strength = proposedStrength.isFinite
            ? min(max(proposedStrength, 0), 1)
            : 0
        let upwardRoom = proposedUpwardRoom.isFinite
            ? max(0, proposedUpwardRoom)
            : 0
        let nominalTravel = min(
            radius * 2 * targetDiameterMultiplier,
            maximumTargetTravel
        )
        let strengthScale = minimumStrengthScale
            + (1 - minimumStrengthScale) * strength
        let targetTravel = min(nominalTravel * strengthScale, upwardRoom)
        let safeDuration = max(CGFloat(flightDuration), 0.001)
        let verticalVelocity = min(
            maximumVerticalVelocity,
            targetTravel / (safeDuration * estimatedVelocityRetention)
        )
        let horizontalVelocity = min(
            maximumHorizontalVelocity,
            nominalTravel * strengthScale
                * horizontalTravelFraction / safeDuration
        )
        let returnVelocity = targetTravel > 0
            ? max(130, verticalVelocity * 0.92)
            : 0
        return JarTapLaunchPlan(
            targetTravel: targetTravel,
            verticalVelocity: verticalVelocity,
            horizontalVelocity: horizontalVelocity,
            returnVelocity: returnVelocity
        )
    }
}

/// Converts the same physical impulse to a mass-aware velocity change, then
/// applies an explicit component-wise ceiling. This keeps tiny bodies stable
/// without flattening the slower response of a larger aggregate.
enum JarShakeVelocityPolicy {
    static func velocity(
        current: CGVector,
        impulse: CGVector,
        mass: CGFloat,
        maximumHorizontalVelocity: CGFloat = Constants.Jar.shakeMaximumHorizontalVelocity,
        maximumVerticalVelocity: CGFloat = Constants.Jar.shakeMaximumVerticalVelocity
    ) -> CGVector {
        let horizontalLimit = max(0, maximumHorizontalVelocity.isFinite
            ? maximumHorizontalVelocity
            : 0)
        let verticalLimit = max(0, maximumVerticalVelocity.isFinite
            ? maximumVerticalVelocity
            : 0)
        let currentDX = current.dx.isFinite ? current.dx : 0
        let currentDY = current.dy.isFinite ? current.dy : 0
        guard impulse.dx.isFinite,
              impulse.dy.isFinite,
              mass.isFinite,
              mass > 0
        else {
            return CGVector(
                dx: min(max(currentDX, -horizontalLimit), horizontalLimit),
                dy: min(max(currentDY, -verticalLimit), verticalLimit)
            )
        }
        return CGVector(
            dx: min(max(currentDX + impulse.dx / mass, -horizontalLimit), horizontalLimit),
            dy: min(max(currentDY + impulse.dy / mass, -verticalLimit), verticalLimit)
        )
    }
}

/// A deterministic monotonic-time gate shared by pointer and accessibility
/// nudge entry points, preventing key repeat or gesture duplication from
/// stacking an unbounded series of impulses.
struct JarGestureRateLimiter {
    private(set) var lastAcceptedUptime = -Double.greatestFiniteMagnitude

    mutating func accepts(uptime: TimeInterval, cooldown: TimeInterval) -> Bool {
        guard uptime.isFinite, cooldown.isFinite else { return false }
        let safeCooldown = max(0, cooldown)
        guard uptime >= lastAcceptedUptime,
              uptime - lastAcceptedUptime >= safeCooldown
        else { return false }
        lastAcceptedUptime = uptime
        return true
    }
}

struct JarInteractionCollisionDecision: Equatable {
    let playSound: Bool
    let playHaptic: Bool
}

/// Follow-up collisions are feedback from one explicit gesture, not a general
/// microphone for a constantly settling physics world. Each gesture opens one
/// short window with independent sound and haptic budgets.
struct JarInteractionCollisionBudget {
    private(set) var opensAtUptime = Double.greatestFiniteMagnitude
    private(set) var closesAtUptime = -Double.greatestFiniteMagnitude
    private(set) var remainingSounds = 0
    private(set) var remainingHaptics = 0

    mutating func begin(
        uptime: TimeInterval,
        muteDuration: TimeInterval,
        followUpDuration: TimeInterval,
        soundLimit: Int,
        hapticLimit: Int
    ) {
        guard uptime.isFinite,
              muteDuration.isFinite,
              followUpDuration.isFinite
        else {
            cancel()
            return
        }
        opensAtUptime = uptime + max(0, muteDuration)
        closesAtUptime = uptime + max(0, followUpDuration)
        remainingSounds = max(0, soundLimit)
        remainingHaptics = max(0, hapticLimit)
    }

    mutating func cancel() {
        opensAtUptime = Double.greatestFiniteMagnitude
        closesAtUptime = -Double.greatestFiniteMagnitude
        remainingSounds = 0
        remainingHaptics = 0
    }

    func isOpen(uptime: TimeInterval) -> Bool {
        uptime.isFinite
            && uptime >= opensAtUptime
            && uptime <= closesAtUptime
            && (remainingSounds > 0 || remainingHaptics > 0)
    }

    mutating func consume(
        uptime: TimeInterval,
        soundReady: Bool,
        hapticReady: Bool
    ) -> JarInteractionCollisionDecision {
        guard isOpen(uptime: uptime) else {
            return JarInteractionCollisionDecision(playSound: false, playHaptic: false)
        }
        let playSound = soundReady && remainingSounds > 0
        let playHaptic = hapticReady && remainingHaptics > 0
        if playSound { remainingSounds -= 1 }
        if playHaptic { remainingHaptics -= 1 }
        return JarInteractionCollisionDecision(
            playSound: playSound,
            playHaptic: playHaptic
        )
    }
}

/// Rejects callbacks from a stopped or superseded Core Motion run. Gem physics
/// accepts both tilt and shake input regardless of decorative motion preferences.
struct JarMotionUpdateGate {
    private(set) var generation: UInt64 = 0
    private(set) var isActive = false

    mutating func begin() -> UInt64 {
        generation &+= 1
        isActive = true
        return generation
    }

    mutating func invalidate() {
        isActive = false
        generation &+= 1
    }

    func accepts(_ candidate: UInt64) -> Bool {
        isActive && generation == candidate
    }

    func acceptsGravity(_ candidate: UInt64, reduceMotion: Bool) -> Bool {
        accepts(candidate)
    }
}

struct JarShakeEvent: Equatable, Sendable {
    let strength: Double
    let horizontalDirection: Double
}

/// Recognizes a deliberate back-and-forth shake from gravity-free device
/// acceleration. A single bump, ordinary tilt, and the app's own haptic pulse
/// cannot independently satisfy the two opposing peaks plus rearm window.
struct JarShakeDetector {
    private struct Peak {
        let timestamp: TimeInterval
        let magnitude: Double
        let x: Double
        let y: Double
        let z: Double
    }

    private var firstPeak: Peak?
    private var belowRearmSince: TimeInterval?
    private var lastTriggerUptime = -Double.greatestFiniteMagnitude
    private var selfFeedbackIgnoreUntilUptime = -Double.greatestFiniteMagnitude
    /// Unlike detector state, an app-originated haptic can outlive a stop/start
    /// boundary. `reset()` intentionally preserves this monotonic deadline.
    private var externalSuppressUntilUptime = -Double.greatestFiniteMagnitude
    private(set) var isArmed = true

    mutating func reset() {
        firstPeak = nil
        belowRearmSince = nil
        lastTriggerUptime = -Double.greatestFiniteMagnitude
        selfFeedbackIgnoreUntilUptime = -Double.greatestFiniteMagnitude
        isArmed = true
    }

    mutating func suppress(until uptime: TimeInterval) {
        guard uptime.isFinite else { return }
        externalSuppressUntilUptime = max(externalSuppressUntilUptime, uptime)
        // A peak sampled before our own haptic must never pair with a peak
        // sampled after it, even when the advertised pattern is very short.
        firstPeak = nil
        belowRearmSince = nil
    }

    mutating func ingest(
        x: Double,
        y: Double,
        z: Double,
        uptime: TimeInterval
    ) -> JarShakeEvent? {
        guard x.isFinite, y.isFinite, z.isFinite, uptime.isFinite else { return nil }
        let magnitude = sqrt(x * x + y * y + z * z)
        guard magnitude.isFinite else { return nil }
        let ignoreUntilUptime = max(
            selfFeedbackIgnoreUntilUptime,
            externalSuppressUntilUptime
        )

        if magnitude <= Constants.Jar.deviceShakeRearmThreshold {
            if belowRearmSince == nil { belowRearmSince = uptime }
            if let belowRearmSince,
               uptime - belowRearmSince >= Constants.Jar.deviceShakeRearmDuration,
               uptime >= ignoreUntilUptime,
               uptime - lastTriggerUptime >= Constants.Jar.deviceShakeCooldown {
                isArmed = true
                firstPeak = nil
            }
            return nil
        }
        belowRearmSince = nil

        guard isArmed,
              uptime >= ignoreUntilUptime,
              uptime - lastTriggerUptime >= Constants.Jar.deviceShakeCooldown,
              magnitude >= Constants.Jar.deviceShakeThreshold
        else { return nil }

        let current = Peak(
            timestamp: uptime,
            magnitude: magnitude,
            x: x / magnitude,
            y: y / magnitude,
            z: z / magnitude
        )
        guard let firstPeak else {
            self.firstPeak = current
            return nil
        }
        guard uptime >= firstPeak.timestamp else {
            self.firstPeak = current
            return nil
        }
        guard uptime - firstPeak.timestamp <= Constants.Jar.deviceShakeReversalWindow else {
            self.firstPeak = current
            return nil
        }

        let directionDot = firstPeak.x * current.x
            + firstPeak.y * current.y
            + firstPeak.z * current.z
        guard directionDot <= Constants.Jar.deviceShakeReversalDotMaximum else {
            if current.magnitude > firstPeak.magnitude {
                self.firstPeak = current
            }
            return nil
        }

        let strongestMagnitude = max(firstPeak.magnitude, current.magnitude)
        let normalizedStrength = (
            strongestMagnitude - Constants.Jar.deviceShakeThreshold
        ) / max(3.2 - Constants.Jar.deviceShakeThreshold, 0.1)
        let strength = min(max(0.35 + normalizedStrength * 0.65, 0.35), 1)
        let horizontalDelta = current.x - firstPeak.x
        let horizontalDirection = min(max(horizontalDelta, -1), 1)

        self.firstPeak = nil
        isArmed = false
        lastTriggerUptime = uptime
        selfFeedbackIgnoreUntilUptime = uptime + Constants.Jar.deviceShakeHapticGuard
        return JarShakeEvent(
            strength: strength,
            horizontalDirection: horizontalDirection
        )
    }
}

/// Samples device motion for one jar (Docs/GemExperienceDesign.md §7.13).
/// While the jar is awake it runs at the full rate on the main queue and
/// applies every sample, as before. When the jar comes to rest it drops
/// to `JarMotionRate.idleUpdatesPerSecond` on a background queue, where
/// `JarIdleTiltMonitor` keeps the smoothed tilt; only a tilt that would move
/// the drawn light (or a shake peak) hops to main, which restores the full
/// rate and the render loop. Stopped whenever the jar's owner says so (Home
/// hidden or covered, the app not active, no study gem).
@MainActor
final class JarMotionObserver: ObservableObject {
    private static weak var activeOwner: JarMotionObserver?

    private let source: JarMotionSource
    private weak var scene: JarScene?
    private var updateGate = JarMotionUpdateGate()
    private var shakeDetector = JarShakeDetector()
    private var appliesGravity = true
    private var hapticPlaybackObserver: NSObjectProtocol?
    private let idleMonitor = JarIdleTiltMonitor()
    /// The idle rate is delivered here, off the main thread.
    private let idleQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "PomoGem.JarMotion.idle"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()
    private var demandSubscription: AnyCancellable?
    private var isStarted = false
    /// The rate the sensor runs at now (tests and the Debug frame probe).
    private(set) var rate: JarMotionRate = .stopped {
        didSet {
#if DEBUG && targetEnvironment(simulator)
            JarFrameProbe.shared?.motionRate = rate
#endif
        }
    }

    init(scene: JarScene? = nil, source: JarMotionSource? = nil) {
        self.scene = scene
        self.source = source ?? Self.makeDefaultSource()
        hapticPlaybackObserver = NotificationCenter.default.addObserver(
            forName: HapticPlaybackNotification.willPlay,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let advertisedDuration = (
                notification.userInfo?[HapticPlaybackNotification.durationKey] as? NSNumber
            )?.doubleValue ?? 0
            guard advertisedDuration.isFinite else { return }
            let suppressUntil = ProcessInfo.processInfo.systemUptime
                + max(0, advertisedDuration)
                + Constants.Jar.deviceShakeHapticGuard
            MainActor.assumeIsolated { [weak self] in
                self?.shakeDetector.suppress(until: suppressUntil)
            }
        }
    }

    deinit {
        if let hapticPlaybackObserver {
            NotificationCenter.default.removeObserver(hapticPlaybackObserver)
        }
    }

    private static func makeDefaultSource() -> JarMotionSource {
#if DEBUG && targetEnvironment(simulator)
        if let synthetic = SyntheticJarMotionSource.forCurrentProcess() {
            return synthetic
        }
#endif
        return CoreMotionJarMotionSource()
    }

    func start(scene: JarScene? = nil, appliesGravity: Bool = true) {
        if let scene, scene !== self.scene {
            if isStarted { stop() }
            self.scene = scene
        }
        self.appliesGravity = appliesGravity
        guard let scene = self.scene,
              source.isAvailable
        else { return }
        if let previousOwner = Self.activeOwner, previousOwner !== self {
            previousOwner.stop()
        }
        Self.activeOwner = self
        isStarted = true
        // Reduce Motion may have changed since the idle check was armed.
        idleMonitor.setFollowsTilt(!scene.reduceMotion)
        guard demandSubscription == nil else { return }
        // The subject hands over the current demand at once, then every
        // change, synchronously on the main actor.
        demandSubscription = scene.fullRateMotionDemand
            .removeDuplicates()
            .sink { [weak self] wantsFullRate in
                self?.follow(jarWantsFullRate: wantsFullRate)
            }
    }

    func stop() {
        // Invalidate before stopping/resetting so a delivery already queued by
        // Core Motion cannot overwrite the stable downward gravity afterward.
        updateGate.invalidate()
        idleMonitor.disarm()
        demandSubscription = nil
        isStarted = false
        appliesGravity = false
        source.stop()
        rate = .stopped
        shakeDetector.reset()
        scene?.resetGravity()
        if Self.activeOwner === self {
            Self.activeOwner = nil
        }
    }

    private func follow(jarWantsFullRate: Bool) {
        guard isStarted else { return }
        switch JarMotionRate.resolve(sampling: .tiltAndShake, jarWantsFullRate: jarWantsFullRate) {
        case .full where rate != .full:
            runFullRate()
        case .idle where rate != .idle:
            runIdleRate()
        default:
            break
        }
    }

    /// The awake jar: every sample, on the main queue.
    private func runFullRate() {
        // Set first: the gravity catch-up below can itself raise the jar's
        // demand, which must find the full rate already running.
        rate = .full
        let latestIdleGravity = idleMonitor.disarm()
        let generation = updateGate.begin()
        shakeDetector.reset()
        source.start(
            updatesPerSecond: JarMotionRate.fullUpdatesPerSecond,
            queue: .main
        ) { [weak self] sample in
            // OperationQueue.main is the delivery contract. Consume each sample
            // synchronously so 30 Hz input cannot accumulate as unordered,
            // stale unstructured tasks behind a busy SpriteKit frame.
            MainActor.assumeIsolated {
                self?.ingestFullRate(sample, generation: generation)
            }
        }
        // What the idle check saw last becomes the gravity now, so a jar
        // woken by a tap never starts from a stale tilt, and a tilt that
        // woke it moves the light at once.
        if appliesGravity, let latestIdleGravity {
            scene?.setGravityVector(latestIdleGravity, smoothing: false)
        }
    }

    /// The resting jar: a few samples a second, checked off the main thread.
    private func runIdleRate() {
        guard let scene else { return }
        rate = .idle
        let generation = updateGate.begin()
        idleMonitor.arm(
            JarIdleTiltFilter(
                gravity: scene.appliedGravityVector,
                drawnLight: scene.opticalTiltFraction,
                followsTilt: !scene.reduceMotion
            ),
            generation: generation
        )
        let monitor = idleMonitor
        source.start(
            updatesPerSecond: JarMotionRate.idleUpdatesPerSecond,
            queue: idleQueue
        ) { [weak self] sample in
            // Core Motion's background queue: only the monitor is touched.
            guard let wake = monitor.ingest(sample, generation: generation) else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.handleIdleWake(wake, generation: generation)
                }
            }
        }
    }

    private func handleIdleWake(_ wake: JarIdleWake, generation: UInt64) {
        guard rate == .idle,
              updateGate.accepts(generation),
              let scene
        else { return }
        // The sample that woke the jar starts a gesture: full rate at once.
        // Its smoothed gravity is applied there; a tilt that moves the light
        // restarts the render loop and holds the full rate (JarScene).
        runFullRate()
        if wake.reason == .shake {
            // The reversal of a shake follows within 0.42 s.
            scene.holdFullRateMotion()
            ingestShake(wake.sample)
        }
        // Nothing to draw after all (the light already follows this tilt):
        // rest again, re-armed around the light on screen.
        if !scene.wantsFullRateMotion {
            runIdleRate()
        }
    }

    private func ingestFullRate(_ sample: JarMotionSample, generation: UInt64) {
        guard let scene,
              updateGate.accepts(generation)
        else { return }
        if appliesGravity,
           updateGate.acceptsGravity(generation, reduceMotion: scene.reduceMotion) {
            scene.setGravityVector(sample.proposedGravity)
        }
        ingestShake(sample)
    }

    private func ingestShake(_ sample: JarMotionSample) {
        guard let scene,
              let shake = shakeDetector.ingest(
                x: sample.accelerationX,
                y: sample.accelerationY,
                z: sample.accelerationZ,
                uptime: sample.timestamp
              )
        else { return }
        _ = scene.shakePebbles(
            strength: CGFloat(shake.strength),
            horizontal: CGFloat(shake.horizontalDirection)
        )
    }

#if DEBUG
    /// Test seam: whether the idle tilt check is armed.
    var isIdleCheckArmedForTesting: Bool { idleMonitor.isArmed }
#endif
}
