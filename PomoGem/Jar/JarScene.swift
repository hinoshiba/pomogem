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

    var showsMonthLabels = false {
        didSet { renderBaseLayers() }
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
    private(set) var isBakeInProgress = false
    private(set) var isCapacityReliefActive = false
    private(set) var appliedGravityVector = Constants.Jar.gravityVector
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
    private var transientMotionGate = JarTransientMotionGate()
    private var sensorySequence: UInt64 = 0
    private var opticalTiltFraction: CGFloat = 0
    private var lastPublishedPhysicalPebbleCount = 0
    private var earlyEffortSpotlightIDs = Set<UUID>()

    private var outerJarRect: CGRect {
        let jarWidth = max(size.width - Constants.Jar.horizontalMargin * 2, 1)
        let jarHeight = min(Constants.Jar.height, max(size.height, 1))
        return CGRect(
            x: (size.width - jarWidth) / 2,
            y: max((size.height - jarHeight) / 2, 0),
            width: jarWidth,
            height: jarHeight
        )
    }

    private var interiorRect: CGRect {
        let outer = outerJarRect
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
        min(50, outerJarRect.width * 0.14)
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

    private var bakeEligibleRadii: [Double] {
        bakeEligiblePebbles.map { Double($0.radius) }
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
            worldNode.childNode(withName: "obstacle.fusion")?.removeFromParent()
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
            for (index, descriptor) in additions.enumerated() {
                acceptedPebbleIDs.insert(descriptor.id)
                let node = PebbleNode(
                    descriptor: descriptor,
                    reduceMotion: reduceMotion,
                    rareRewardMode: rareRewardMode
                )
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
                worldNode.addChild(node)
            }
        }
        guard !removedIDs.isEmpty || !additions.isEmpty || previousTotal != screenTimeObstacleUnitCount else { return }
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
            ScreenTimeObstacleAppearance.apply(to: fragment, descriptor: obstacle, radius: source.radius)
            fragment.position = source.position
            fragment.zRotation = source.zRotation
            fragment.zPosition = JarZPosition.pebble
            effect.addChild(fragment)
            fragment.run(.group([
                .move(to: point, duration: 0.28),
                .scale(to: 0.25, duration: 0.28),
                .fadeOut(withDuration: 0.28)
            ]))
        }
        effect.run(.sequence([.wait(forDuration: 0.3), .removeFromParent()]))
        let node = PebbleNode(
            descriptor: destination,
            reduceMotion: reduceMotion,
            rareRewardMode: rareRewardMode
        )
        let range = allowedHorizontalRange(at: point.y, radius: node.radius)
        node.position = CGPoint(
            x: min(max(point.x, range.lowerBound), range.upperBound),
            y: min(max(point.y + 12, currentFloorY + node.radius + 6), interiorRect.maxY - node.radius)
        )
        node.setScale(0.4)
        node.alpha = 0.25
        node.physicsBody?.velocity = CGVector(dx: 0, dy: 32)
        node.run(.group([.scale(to: 1, duration: 0.28), .fadeIn(withDuration: 0.28)]))
        acceptedPebbleIDs.insert(destination.id)
        worldNode.addChild(node)
        return destination.id
    }
    /// Observation-only test seam: a tap must actively drive exactly one body.
    /// Other gems move only when SpriteKit resolves a real contact.
    var activeTapDrivenBodyCount: Int { pendingTapKick?.kicks.count ?? 0 }
    var activeTapMotionPebbleID: UUID? { activeTapMotion?.pebbleID }
    var isInteractionMotionActive: Bool { interactionMotionWindow != nil }
    var snapshotRect: CGRect { outerJarRect }

    /// Share of the interior height left free between the highest body and
    /// the mouth (worst-case capacity reviews; presentation only).
    var pileHeadroomFraction: CGFloat {
        let interior = interiorRect
        let top = livePebbles.map { $0.position.y + $0.radius }.max() ?? interior.minY
        return max(0, (interior.maxY - top) / max(interior.height, 1))
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
    }

    override func didMove(to view: SKView) {
        view.preferredFramesPerSecond = Constants.Jar.targetFramesPerSecond
        view.ignoresSiblingOrder = true
        view.allowsTransparency = true
        soundSynth.prepare()
        haptics.prepare()
        rebuildGeometry()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        rebuildGeometry()
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
        worldNode.childNode(withName: "obstacle.fusion")?.removeFromParent()

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
        for descriptor in initiallyVisible {
            let node = PebbleNode(
                descriptor: descriptor,
                reduceMotion: reduceMotion,
                rareRewardMode: rareRewardMode
            )
            if cursorX + node.radius * 2 > interiorRect.maxX {
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
            worldNode.addChild(node)
            cursorX += node.radius * 2
        }
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
        for (index, descriptor) in additions.enumerated() {
            guard acceptedPebbleIDs.insert(descriptor.id).inserted else { continue }
            let node = PebbleNode(
                descriptor: descriptor,
                reduceMotion: reduceMotion,
                rareRewardMode: rareRewardMode
            )
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
            worldNode.addChild(node)
        }
        installedHistoryIDs = wantedIDs
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

        let node = PebbleNode(
            descriptor: descriptor,
            reduceMotion: reduceMotion,
            rareRewardMode: rareRewardMode
        )
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
        worldNode.addChild(node)
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
            pebble.physicsBody?.applyImpulse(CGVector(
                dx: safeDirection * Constants.Jar.shakeHorizontalImpulse,
                dy: Constants.Jar.shakeVerticalImpulseMin * 0.25
            ))
        }
        playSensoryFeedback(
            trigger: .tap,
            samples: pebbles.map {
                JarSensorySample(radius: Double($0.radius), coupling: 0.45)
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
                mass: CGFloat(body.mass)
            )
        }
        playTapCaustic(at: centroid, expands: !reduceMotion)
        playSensoryFeedback(
            trigger: .shake,
            samples: pebbles.map {
                JarSensorySample(radius: Double($0.radius), coupling: 1)
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
                    radius: Double($0.pebble.radius),
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
        tapCausticNode.run(action, withKey: ActionKey.tapCaustic)
    }

    private func playReducedMotionHighlight() {
        reducedMotionHighlightNode.removeAction(forKey: ActionKey.reducedMotionHighlight)
        reducedMotionHighlightNode.alpha = 0
        reducedMotionHighlightNode.run(
            .sequence([
                .fadeAlpha(to: 1, duration: 0.07),
                .wait(forDuration: 0.06),
                .fadeOut(withDuration: 0.14)
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
        guard proposed.dx.isFinite, proposed.dy.isFinite else { return }
        let magnitude = hypot(proposed.dx, proposed.dy)
        let maximum = max(Constants.Jar.maximumExternalGravityMagnitude, 0.1)
        let scale = magnitude > maximum ? maximum / magnitude : 1
        let clamped = CGVector(dx: proposed.dx * scale, dy: proposed.dy * scale)
        let next: CGVector
        if smoothing {
            let fraction = min(max(Constants.Jar.gravitySmoothingFactor, 0), 1)
            next = CGVector(
                dx: appliedGravityVector.dx
                    + (clamped.dx - appliedGravityVector.dx) * fraction,
                dy: appliedGravityVector.dy
                    + (clamped.dy - appliedGravityVector.dy) * fraction
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
        updateOpticalTilt(horizontal: next.dx)
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
    }

    /// Reflections move a few points opposite the sensed gravity, producing a
    /// lens-like parallax response without rotating text or the whole screen.
    /// Reduce Motion removes this simulated depth while keeping physics stable.
    private func updateOpticalTilt(horizontal: CGFloat) {
        let fraction = reduceMotion
            ? CGFloat.zero
            : min(max(horizontal / Constants.Jar.tiltGravityHorizontalScale, -1), 1)
        opticalTiltFraction = fraction
        glassHighlightNode.position.x = outerJarRect.midX + fraction * 6
        backGlassNode.position.x = fraction * -1.6
        mouthDepthNode.position.x = fraction * -0.55
        innerRimNode.position.x = fraction * 0.35
        updateCollarTilt(fraction)
        livePebbles.forEach { $0.updatePresentationLighting(horizontal: fraction) }
    }

    func resumeSimulation() {
        if isPaused { isPaused = false }
        if isIdlePaused {
            isIdlePaused = false
            onIdlePauseChanged?(false)
        }
        resetIdleObservation()
    }

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
        let capacity = StrataMath.capacityUnits(pebbleRadii: bakeEligibleRadii)
        if capacity >= Constants.Jar.aggregateCapacityUnits {
            isCapacityReliefActive = true
        } else if capacity <= Constants.Jar.postAggregateCapacityUnits {
            isCapacityReliefActive = false
        }
        if !isBakeInProgress, needsAggregation {
            _ = beginBakeIfNeeded(force: false)
        }
        processDropQueue()
        publishPhysicalContentChangeIfNeeded()
        updateRareTwinkles()
        updateGemTwinkles(now: currentTime)
        if abs(currentTime - lastPileLightRefresh) >= 0.5 {
            lastPileLightRefresh = currentTime
            refreshPileLight()
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
        worldNode.addChild(pileGlowNode)
        pileGlowNode.blendMode = .add
        pileGlowNode.colorBlendFactor = 1
        pileGlowNode.alpha = 0
        pileGlowNode.zPosition = JarZPosition.strata + 0.6

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
    }

    private func rebuildGeometry() {
        guard size.width > .zero, size.height > .zero else { return }
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
        tapCausticNode.zPosition = JarZPosition.glass + 1.5

        rebuildCollar()

        floorGlowNode.size = CGSize(width: outer.width * 0.98, height: 72)
        floorGlowNode.position = CGPoint(x: outer.midX, y: interiorRect.minY + 4)
        floorGlowNode.color = UIColor(red: 1, green: 0.62, blue: 0.42, alpha: 1)
        floorGlowNode.colorBlendFactor = 1
        floorGlowNode.blendMode = .add
        floorGlowNode.alpha = reduceTransparency ? 0.12 : 0.28
        floorGlowNode.zPosition = JarZPosition.strata + 0.5

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

    private static func jarPath(in rect: CGRect, neckInset: CGFloat) -> CGPath {
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
            context.setFillColor(JarPalette.color(hex: Constants.Color.glassAbsorption).withAlphaComponent(0.24).cgColor)
            context.fill(CGRect(origin: .zero, size: renderSize))
            // Inner shadow in the lower back corners and under the shoulders.
            for center in [
                CGPoint(x: 0, y: height), CGPoint(x: width, y: height),
                CGPoint(x: width * 0.08, y: shoulderY + 10), CGPoint(x: width * 0.92, y: shoulderY + 10)
            ] {
                let shade = [
                    UIColor(red: 0.01, green: 0.02, blue: 0.06, alpha: 0.30).cgColor,
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
                warm.withAlphaComponent(0.50).cgColor,
                UIColor.white.withAlphaComponent(0.60).cgColor,
                cool.withAlphaComponent(0.50).cgColor,
                UIColor.clear.cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: space,
                colors: caustic,
                locations: [0.04, 0.26, 0.5, 0.74, 0.96]
            ) {
                for (y, thickness, alpha) in [(height - 10, CGFloat(1.2), CGFloat(1)), (height - 2.5, CGFloat(1), CGFloat(0.55))] {
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

            // Warm left rim (coral → peach) and cool right rim (cyan → blue).
            innerRim(context, colors: [warm, peach], alpha: 0.9, depth: 10, fromLeft: true)
            innerRim(context, colors: [cool, blue], alpha: 0.8, depth: 10, fromLeft: false)

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
                    UIColor.white.withAlphaComponent(0.08).cgColor,
                    UIColor.white.withAlphaComponent(0.04).cgColor,
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
            // Shoulder light (α0.7) on the right shoulder, a warmer one left.
            for (fromLeft, color, alpha) in [(false, GemColor(cool).mixed(with: .white, amount: 0.5).withAlpha(1), CGFloat(0.7)), (true, peach, CGFloat(0.42))] {
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
    /// shade #5A2E22, vertical anisotropic highlight bands whose position
    /// follows the tilt state, and up to six engraved milestone marks on the
    /// lower edge. The mouth stays open.
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
            let vertical = [highlight.cgColor, base.cgColor, base.cgColor, shade.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: vertical, locations: [0, 0.28, 0.62, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 0, y: height + 2),
                    options: []
                )
            }
            // Horizontal shading: the band turns away at both ends.
            let ends = [
                shade.withAlphaComponent(0.55).cgColor,
                UIColor.clear.cgColor,
                UIColor.clear.cgColor,
                shade.withAlphaComponent(0.65).cgColor
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
                (0.20 + shift, 0.07, CGFloat(0.75)),
                (0.34 + shift, 0.025, CGFloat(0.45)),
                (0.80 + shift, 0.05, CGFloat(0.55))
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
            context.setStrokeColor(shade.withAlphaComponent(0.9).cgColor)
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
        let outer = outerJarRect
        let mouthWidth = outer.width - neckInset * 2
        let width = mouthWidth + 8
        let height: CGFloat = 17
        collarNode.position = CGPoint(x: outer.midX, y: outer.maxY - 9.5)
        collarNode.zPosition = JarZPosition.glass + 1.1
        for (node, tilt) in [(collarLeftNode, -1), (collarCenterNode, 0), (collarRightNode, 1)] {
            node.texture = Self.collarTexture(width: width, tilt: tilt, marks: milestoneTraceCount)
            node.size = CGSize(width: width, height: height)
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
        let node = PebbleNode(
            descriptor: descriptor,
            reduceMotion: reduceMotion,
            rareRewardMode: rareRewardMode
        )
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
        worldNode.addChild(node)
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
            selected.forEach { pebble in
                pebble.run(
                    .group([
                        .fadeOut(withDuration: Constants.Jar.aggregateFormationDuration),
                        .move(to: formationPoint, duration: Constants.Jar.aggregateFormationDuration),
                        .scale(
                            to: Constants.Jar.bakePebbleFinalScale,
                            duration: Constants.Jar.aggregateFormationDuration
                        )
                    ])
                )
            }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Constants.Jar.aggregateFormationDuration
            ) { [weak self] in
                self?.completeActiveBake(token: bakeToken)
            }
        }
        return true
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
        if !livePebbles.contains(where: { $0.descriptor.id == descriptor.id }) {
            _ = acceptedPebbleIDs.insert(descriptor.id)
            let aggregateNode = PebbleNode(
                descriptor: descriptor,
                reduceMotion: reduceMotion,
                rareRewardMode: rareRewardMode
            )
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
            aggregateNode.setScale(0.38)
            aggregateNode.alpha = 0.25
            aggregateNode.physicsBody?.velocity = CGVector(
                dx: 0,
                dy: Constants.Jar.aggregateBirthImpulse
            )
            worldNode.addChild(aggregateNode)
            presentFusionFinale(for: aggregateNode)
        }
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
                JarSensorySample(radius: Double($0.radius), coupling: 1)
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
        for index in 0..<Constants.Jar.dustCount {
            let angle = CGFloat(index) / CGFloat(max(Constants.Jar.dustCount, 1)) * .pi
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
            )
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
                            duration: Constants.Jar.dustLifetime
                        ),
                        .fadeOut(withDuration: Constants.Jar.dustLifetime),
                        .scale(
                            to: Constants.Jar.dustFinalScale,
                            duration: Constants.Jar.dustLifetime
                        )
                    ]),
                    .removeFromParent()
                ])
            )
        }
    }

    private func spawnSparks(at point: CGPoint, color: UIColor, mark: String) {
        guard !reduceMotion else { return }
        for index in 0..<Constants.Jar.goldSparkCount {
            let angle = CGFloat(index) / CGFloat(max(Constants.Jar.goldSparkCount, 1)) * .pi * 2
            let spark = SKLabelNode(fontNamed: "HiraginoSans-W6")
            spark.name = "drop.spark"
            spark.text = mark
            spark.fontSize = Constants.Jar.measuredRadius * Constants.Jar.sparkFontScale
            spark.fontColor = color
            spark.position = point
            spark.zPosition = JarZPosition.effect
            worldNode.addChild(spark)
            let distance = Constants.Jar.touchRadius * Constants.Jar.sparkDistanceScale
            spark.run(
                .sequence([
                    .group([
                        .moveBy(
                            x: cos(angle) * distance,
                            y: sin(angle) * distance,
                            duration: Constants.Jar.goldPreDropDuration
                        ),
                        .fadeOut(withDuration: Constants.Jar.goldPreDropDuration),
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
        let amplitude = min(
            Constants.Jar.screenShakeMaxAmplitude,
            Constants.Jar.screenShakeBaseAmplitude + impactSpeed
        )
        cameraNode.removeAction(forKey: ActionKey.cameraShake)
        cameraNode.position = cameraRestPosition
        let rest = cameraRestPosition
        let shake = SKAction.customAction(withDuration: Constants.Jar.dustLifetime) {
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
    /// meaning. Off with Reduce Motion, Low Power Mode and serious heat.
    private func updateGemTwinkles(now: TimeInterval) {
        guard !reduceMotion,
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
    private func refreshPileLight() {
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
        for pebble in livePebbles where !pebble.isRemovedForBake
            && !pebble.descriptor.isScreenTimeObstacle
            && !pebble.descriptor.isTutorial {
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
            if pebble.descriptor.isAggregate {
                aggregates.append(pebble)
                if heaviest == nil || pebble.descriptor.grams > heaviest?.descriptor.grams ?? 0 {
                    heaviest = pebble
                }
            }
        }
        aggregates.forEach { $0.setPileEmphasis($0 === heaviest) }
        guard weight > 0 else {
            pileGlowNode.alpha = 0
            pileGlowBaseAlpha = 0
            return
        }
        let mean = GemColor(red: red / weight, green: green / weight, blue: blue / weight)
        // Warm-biased (60 % #FF9E6B) so a blue/violet pile still reads as
        // lit rather than foggy.
        pileGlowNode.color = mean.mixed(with: GemColor(hex: "#FF9E6B"), amount: 0.6).withAlpha(1)
        let width = max(120, (maxX - minX) * 1.3)
        let height = min(max(84, (maxY - minY) * 1.8), width * 0.75)
        pileGlowNode.size = CGSize(width: width, height: height)
        // Seated on the floor so the base lens catches the pile's light.
        pileGlowNode.position = CGPoint(
            x: (minX + maxX) / 2,
            y: max((minY + maxY) / 2, currentFloorY + height * 0.22)
        )
        pileGlowBaseAlpha = 0.55 * (reduceTransparency ? 0.45 : 1)
        if pileGlowNode.action(forKey: "jar.pileGlow.pulse") == nil {
            pileGlowNode.alpha = pileGlowBaseAlpha
        }
    }

    /// Landing light: 6–8 soft sparks from the shared glint texture, at most
    /// `maximumEventLightSprites` alive at once, plus a brief pile-light
    /// swell. Reduce Motion never spawns them.
    private func spawnLandingLight(at point: CGPoint, pebble: PebbleNode) {
        guard !reduceMotion, Self.allowsAmbientSparkle else { return }
        pebble.playLandingPulse()
        let tint = GemTone(hex: pebble.descriptor.colorHex, muted: !pebble.descriptor.isMeasured, glass: false)
            .glintUIColor
        let count = 6 + Int(pebble.descriptor.id.presentationHash % 3)
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
            let distance = pebble.radius * (1.3 + CGFloat(index % 3) * 0.45)
            let lifetime: TimeInterval = 0.52
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
            .fadeAlpha(to: min(1, pileGlowBaseAlpha * 1.12), duration: 0.12),
            .fadeAlpha(to: pileGlowBaseAlpha, duration: 0.28)
        ])
        pileGlowNode.run(swell, withKey: "jar.pileGlow.pulse")
    }

    /// Fusion finale by rung: A0 only fades in (200 ms). A1+ adds a white
    /// flash (2.2R, 160 ms), a shock ring (1R → 3R, 420 ms) and a spring
    /// birth (0.6 → 1.08 → 1.0, 380 ms); A2+ adds twelve shards. Reduce
    /// Motion shows a static ring for 600 ms and no motion on the stone.
    private func presentFusionFinale(for node: PebbleNode) {
        let tier = GemCutLadder.aggregateTier(grams: node.descriptor.grams)
        let point = node.position
        if reduceMotion {
            node.setScale(1)
            node.alpha = 1
            guard tier >= 1 else { return }
            let ring = makeFusionRing(at: point, radius: node.radius)
            ring.setScale(2)
            ring.alpha = 0.55
            ring.run(.sequence([.wait(forDuration: 0.6), .removeFromParent()]))
            return
        }
        guard tier >= 1, Self.allowsAmbientSparkle else {
            node.setScale(1)
            node.alpha = 0
            node.run(.fadeIn(withDuration: 0.2))
            return
        }
        node.alpha = 1
        node.setScale(0.6)
        let grow = SKAction.scale(to: 1.08, duration: 0.20)
        grow.timingMode = .easeOut
        let settle = SKAction.scale(to: 1, duration: 0.18)
        settle.timingMode = .easeInEaseOut
        node.run(.sequence([grow, settle]))

        let flash = SKSpriteNode(
            texture: GemArtwork.haloTexture,
            size: CGSize(width: node.radius * 4.4, height: node.radius * 4.4)
        )
        flash.name = "drop.fusionFlash"
        flash.color = .white
        flash.colorBlendFactor = 1
        flash.blendMode = .add
        flash.position = point
        flash.zPosition = JarZPosition.effect
        worldNode.addChild(flash)
        flash.run(.sequence([.fadeOut(withDuration: 0.16), .removeFromParent()]))

        let ring = makeFusionRing(at: point, radius: node.radius)
        let expand = SKAction.scale(to: 3, duration: 0.42)
        expand.timingMode = .easeOut
        ring.run(.sequence([.group([expand, .fadeOut(withDuration: 0.42)]), .removeFromParent()]))

        guard tier >= 2 else { return }
        let tint = GemTone(hex: node.descriptor.colorHex, muted: false, glass: false).glintUIColor
        for index in 0 ..< 12 where eventLightCount < Constants.Jar.maximumEventLightSprites {
            let shard = SKSpriteNode(texture: GemArtwork.glintTexture, size: CGSize(width: 8, height: 8))
            shard.name = "drop.fusionShard"
            shard.color = tint
            shard.colorBlendFactor = 1
            shard.blendMode = .add
            shard.position = point
            shard.zPosition = JarZPosition.effect
            worldNode.addChild(shard)
            eventLightCount += 1
            let angle = CGFloat(index) / 12 * .pi * 2
            let distance = node.radius * 2.6
            let move = SKAction.moveBy(x: cos(angle) * distance, y: sin(angle) * distance, duration: 0.6)
            move.timingMode = .easeOut
            shard.run(.sequence([
                .group([move, .fadeOut(withDuration: 0.6)]),
                .run { [weak self] in self?.eventLightCount -= 1 },
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
        guard !reduceMotion, rareRewardMode.usesEnhancedPresentation else { return }
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
        if movement < Constants.Jar.idleMovementThreshold {
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

    /// Freezes only presentation physics. Study records, aggregate membership,
    /// mass, and cloud state live outside SpriteKit and are never touched.
    private func pauseSettledSimulation() {
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
        // Never freeze a half-lit flare: settle every star to its resting
        // (or tilt-lit) value before the frame stops.
        livePebbles.forEach {
            $0.settleGemTwinkle()
            $0.updatePresentationLighting(horizontal: opticalTiltFraction)
        }
        refreshPileLight()
        if !isIdlePaused {
            isIdlePaused = true
            onIdlePauseChanged?(true)
        }
        isPaused = true
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
        let sceneLights = [floorGlowNode, pileGlowNode, glassHighlightNode]
        sceneLights.forEach { $0.blendMode = .alpha }
        return { [weak self] in
            pebbles.forEach {
                $0.setSnapshotBlending(false)
                $0.updatePresentationLighting(horizontal: self?.opticalTiltFraction ?? 0)
            }
            sceneLights.forEach { $0.blendMode = .add }
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
    /// different body count. `physicalPebbleCount` itself remains computed from
    /// `livePebbles`, avoiding a second, potentially stale emptiness source.
    private func publishPhysicalContentChangeIfNeeded(force: Bool = false) {
        refreshEarlyEffortSpotlightsIfNeeded()
        let count = physicalPebbleCount
        guard force || count != lastPublishedPhysicalPebbleCount else { return }
        lastPublishedPhysicalPebbleCount = count
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

@MainActor
final class JarMotionObserver: ObservableObject {
    private static weak var activeOwner: JarMotionObserver?

    private let manager = CMMotionManager()
    private weak var scene: JarScene?
    private var updateGate = JarMotionUpdateGate()
    private var shakeDetector = JarShakeDetector()
    private var appliesGravity = true
    private var hapticPlaybackObserver: NSObjectProtocol?

    init(scene: JarScene? = nil) {
        self.scene = scene
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

    func start(scene: JarScene? = nil, appliesGravity: Bool = true) {
        if let scene { self.scene = scene }
        self.appliesGravity = appliesGravity
        guard self.scene != nil,
              manager.isDeviceMotionAvailable
        else { return }
        if let previousOwner = Self.activeOwner, previousOwner !== self {
            previousOwner.stop()
        }
        Self.activeOwner = self
        guard !manager.isDeviceMotionActive else { return }
        let generation = updateGate.begin()
        shakeDetector.reset()
        manager.deviceMotionUpdateInterval = 1 / TimeInterval(Constants.Jar.tiltUpdatesPerSecond)
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let gravity = motion.gravity
            let acceleration = motion.userAcceleration
            let timestamp = motion.timestamp
            let horizontal = CGFloat(gravity.x) * Constants.Jar.tiltGravityHorizontalScale
            let sensedVertical = CGFloat(gravity.y) * abs(Constants.Jar.gravity)
            let vertical = min(-Constants.Jar.tiltGravityMinimumDownward, sensedVertical)
            // OperationQueue.main is the delivery contract. Consume each sample
            // synchronously so 30 Hz input cannot accumulate as unordered,
            // stale unstructured tasks behind a busy SpriteKit frame.
            MainActor.assumeIsolated { [weak self] in
                guard let self,
                      let scene = self.scene,
                      self.updateGate.accepts(generation)
                else { return }
                if self.appliesGravity,
                   self.updateGate.acceptsGravity(
                    generation,
                    reduceMotion: scene.reduceMotion
                ) {
                    scene.setGravityVector(
                        CGVector(dx: horizontal, dy: vertical)
                    )
                }
                if let shake = self.shakeDetector.ingest(
                    x: acceleration.x,
                    y: acceleration.y,
                    z: acceleration.z,
                    uptime: timestamp
                ) {
                    _ = scene.shakePebbles(
                        strength: CGFloat(shake.strength),
                        horizontal: CGFloat(shake.horizontalDirection)
                    )
                }
            }
        }
    }

    func stop() {
        // Invalidate before stopping/resetting so a delivery already queued by
        // Core Motion cannot overwrite the stable downward gravity afterward.
        updateGate.invalidate()
        appliesGravity = false
        manager.stopDeviceMotionUpdates()
        shakeDetector.reset()
        scene?.resetGravity()
        if Self.activeOwner === self {
            Self.activeOwner = nil
        }
    }
}
