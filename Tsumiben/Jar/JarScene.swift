import Combine
import CoreMotion
@preconcurrency import SpriteKit
import UIKit

struct JarLandingEvent {
    let pebble: PebbleDescriptor
    let impactSpeed: CGFloat
    let position: CGPoint
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

    var reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled {
        didSet {
            guard reduceMotion != oldValue else { return }
            livePebbles.forEach { $0.setReduceMotion(reduceMotion) }
            if reduceMotion {
                pendingTapKick = nil
                resetGravity()
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
                    "//drop.anticipation.rare"
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

    private struct QueuedDrop {
        let descriptor: PebbleDescriptor
        let horizontalUnit: CGFloat
        var readyUptime: TimeInterval
        var needsSpecialAnticipation: Bool
    }

    private struct ActiveBake {
        let token: UUID
        let request: JarBakeRequest
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

    /// Interaction values are intentionally expressed as velocity changes, then
    /// converted to impulses using each body's mass. A large aggregate and a
    /// small study pebble therefore make the same readable hop without giving
    /// either one unbounded kinetic energy.
    private enum TapResponse {
        static let cooldown: TimeInterval = 0.68
        static let minimumInfluenceRadius: CGFloat = 64
        static let maximumInfluenceRadius: CGFloat = 104
        static let influenceRadiusFraction: CGFloat = 0.28
        static let minimumLocalStrength: CGFloat = 0.04
        static let peakVerticalVelocity: CGFloat = 112
        static let peakRadialVelocity: CGFloat = 42
        static let verticalVariation: CGFloat = 7
        static let maximumVerticalVelocity: CGFloat = 120
        static let returnDelay: TimeInterval = 0.32
        static let baseReturnVelocity: CGFloat = 92
        static let localReturnVelocity: CGFloat = 14
        static let flightDamping: CGFloat = 0.03
        static let settlingDamping: CGFloat = 0.16
        static let restoreDampingDelay: TimeInterval = 0.30
        // A return scheduled by wall-clock time can otherwise win a race with
        // SpriteKit after a short main-thread hitch (including VoiceOver and
        // UI automation). Keep enough simulated frames to make the response
        // visibly travel before the downward beat is allowed to begin.
        static let reinforcementFrameCount = 12
        static let returnFrameRetryDelay: TimeInterval = 0.05
        static let maximumReturnFrameDeferrals = 12
        static let horizontalVariation: CGFloat = 3
        static let maximumHorizontalVelocity: CGFloat = 34
        static let maximumAngularVelocity: CGFloat = 4.2
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
        var remainingFrames: Int
    }

    private let soundSynth: SoundSynth
    private let haptics: Haptics
    private let worldNode = SKNode()
    private let jarShadowNode = SKShapeNode()
    private let backGlassNode = SKShapeNode()
    private let mouthDepthNode = SKShapeNode()
    private let glassNode = SKShapeNode()
    private let baseRefractionNode = SKShapeNode()
    private let baseCausticNode = SKShapeNode()
    private let lensShadeNode = SKShapeNode()
    private let reducedMotionHighlightNode = SKShapeNode()
    private let specularNode = SKShapeNode()
    private let warmReflectionNode = SKShapeNode()
    private let rimNode = SKShapeNode()
    private let innerRimNode = SKShapeNode()
    private let tapCausticNode = SKShapeNode()
    private let wallNode = SKNode()
    private let floorNode = SKNode()
    private let cameraNode = SKCameraNode()
    private let strataRenderer = StrataRenderer()

    private(set) var visualStrata: [JarStratumVisual] = []
    private(set) var bedrock: JarBedrockVisual?
    private(set) var historyDescriptors: [PebbleDescriptor] = []
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
    private var lastTapBounceUptime = -Double.greatestFiniteMagnitude
    private var pendingTapKick: PendingTapKick?
    private var lastSecondaryFeedbackUptime = -Double.greatestFiniteMagnitude
    private var suppressIncidentalFeedbackUntilUptime = -Double.greatestFiniteMagnitude
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
    private var tapSequence: UInt64 = 0
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
        worldNode.children.compactMap { $0 as? PebbleNode }.filter { !$0.isRemovedForBake }
    }

    private var bakeEligiblePebbles: [PebbleNode] {
        livePebbles.filter { $0.descriptor.participatesInBake }
    }

    private var bakeEligibleRadii: [Double] {
        bakeEligiblePebbles.map { Double($0.radius) }
    }

    var physicalPebbleCount: Int { livePebbles.count }
    var physicalAggregateCount: Int { livePebbles.filter { $0.descriptor.isAggregate }.count }
    var representedPebbleCount: Int {
        livePebbles.reduce(0) {
            $0 + ($1.descriptor.aggregate?.pebbleCount ?? ($1.descriptor.isAchievement ? 0 : 1))
        }
    }
    var queuedDropCount: Int { dropQueue.count }
    var snapshotRect: CGRect { outerJarRect }

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
        observeReduceMotion()
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
        observeReduceMotion()
    }

    deinit {
        if let reduceMotionObserver {
            NotificationCenter.default.removeObserver(reduceMotionObserver)
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
        cancelActiveBakeForRestore()
        dropQueue.removeAll()
        mutedLandingIDs.removeAll()
        acceptedPebbleIDs.removeAll()
        acceptedPebbleIDs.formUnion(persistedBakedPebbleIDs)
        suppressIncidentalFeedbackUntilUptime = ProcessInfo.processInfo.systemUptime
            + Constants.Jar.idleWindow
        worldNode.children
            .compactMap { $0 as? PebbleNode }
            .forEach { $0.removeFromParent() }

        var cursorX = interiorRect.minX
        var cursorY = currentFloorY
        var rowHeight = CGFloat.zero

        let combinedDescriptors = historyDescriptors + descriptors.filter {
            !persistedBakedPebbleIDs.contains($0.id)
        }
        let uniqueDescriptors = combinedDescriptors.filter {
            acceptedPebbleIDs.insert($0.id).inserted
        }
        let initiallyVisible = uniqueDescriptors.prefix(Constants.Jar.maxPhysicsBodies)
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
        let overflow = uniqueDescriptors.dropFirst(initiallyVisible.count)
        let now = ProcessInfo.processInfo.systemUptime
        for descriptor in overflow {
            mutedLandingIDs.insert(descriptor.id)
            dropQueue.append(
                QueuedDrop(
                    descriptor: descriptor,
                    horizontalUnit: CGFloat.random(in: -1 ... 1),
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
        publishPhysicalContentChangeIfNeeded()
        resetIdleObservation()
    }

    private func deterministicAngle(for id: UUID) -> CGFloat {
        let value = id.uuidString.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return (CGFloat(abs(value % 10_000)) / 10_000 * 2 - 1) * .pi
    }

    /// Reduce Motion keeps a newly earned body in the live physics world, but
    /// starts it at rest on the floor instead of asking the user to follow a
    /// fall, spin, and bounce. UUID-derived placement keeps the result stable
    /// across redraws and devices without flattening the stone's identity.
    private func settleForReduceMotion(_ pebble: PebbleNode) {
        let angle = deterministicAngle(for: pebble.descriptor.id)
        let horizontalUnit = (angle + .pi) / (.pi * 2)
        let y = currentFloorY + pebble.radius
        let horizontalRange = allowedHorizontalRange(at: y, radius: pebble.radius)
        pebble.position = CGPoint(
            x: horizontalRange.lowerBound
                + (horizontalRange.upperBound - horizontalRange.lowerBound) * horizontalUnit,
            y: y
        )
        pebble.zRotation = angle
        pebble.markLanded()
        guard let body = pebble.physicsBody else { return }
        body.velocity = .zero
        body.angularVelocity = .zero
        body.isResting = true
    }

    /// Preserve the semantic landing boundary while omitting its moving
    /// presentation. Restored overflow remains muted exactly as it is for a
    /// physical contact; fresh loose stones still reach Home's receipt path.
    private func deliverReducedMotionLandingIfNeeded(for pebble: PebbleNode) {
        guard mutedLandingIDs.remove(pebble.descriptor.id) == nil else { return }
        deliverLandingFeedback(
            for: pebble,
            speed: Constants.Jar.minimumLandingSpeed,
            point: CGPoint(x: pebble.position.x, y: currentFloorY)
        )
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

    /// Removes items that rotate from the live jar into the permanent record
    /// shelf. Their persistence is untouched, and clearing the accepted IDs
    /// allows an older stone to reappear if a newer synced record is removed.
    func removePebbles(withIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        dropQueue.removeAll { ids.contains($0.descriptor.id) }
        mutedLandingIDs.subtract(ids)
        acceptedPebbleIDs.subtract(ids)
        for pebble in livePebbles where ids.contains(pebble.descriptor.id) {
            pebble.removeFromParent()
        }
        publishPhysicalContentChangeIfNeeded()
        resetIdleObservation()
        resumeSimulation()
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
    func nudge(horizontal direction: CGFloat) {
        let safeDirection = min(max(direction, -1), 1)
        guard abs(safeDirection) > 0.01, !livePebbles.isEmpty else { return }
        if reduceMotion {
            let centroid = CGPoint(
                x: livePebbles.reduce(CGFloat.zero) { $0 + $1.position.x }
                    / CGFloat(livePebbles.count),
                y: livePebbles.reduce(CGFloat.zero) { $0 + $1.position.y }
                    / CGFloat(livePebbles.count)
            )
            playTapCaustic(at: centroid, expands: false)
            soundSynth.playTick()
            haptics.playSecondaryCollision()
            return
        }
        resumeSimulation()
        for pebble in livePebbles {
            pebble.physicsBody?.applyImpulse(CGVector(
                dx: safeDirection * Constants.Jar.shakeHorizontalImpulse,
                dy: Constants.Jar.shakeVerticalImpulseMin * 0.25
            ))
        }
        soundSynth.playTick()
        haptics.playSecondaryCollision()
    }

    /// Sends a compact upward wave through the existing physical bodies.
    ///
    /// This is deliberately a presentation-only interaction: it does not add,
    /// remove, land, aggregate, or otherwise mutate the study records represented
    /// by the bodies. The return value makes the cooldown behavior testable and
    /// lets accessibility callers use the exact same path as a touch.
    @discardableResult
    func bouncePebbles(at proposedPoint: CGPoint? = nil) -> Bool {
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

        resumeSimulation()

        // Reduce Motion keeps feedback pinned to the activation point. No body
        // is displaced and the whole bottle does not flash.
        if reduceMotion {
            playTapCaustic(at: origin, expands: false)
            soundSynth.playTick()
            haptics.playSecondaryCollision()
            return true
        }

        let influenceRadius = min(
            TapResponse.maximumInfluenceRadius,
            max(
                TapResponse.minimumInfluenceRadius,
                interiorRect.width * TapResponse.influenceRadiusFraction
            )
        )
        let impacts: [LocalTapImpact] = pebbles.compactMap { pebble in
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

        // An empty patch of glass still acknowledges the exact touch, but must
        // not cancel a previous pebble's scheduled return-to-rest sequence.
        guard !impacts.isEmpty else {
            playTapCaustic(at: origin)
            soundSynth.playTick()
            haptics.playSecondaryCollision()
            return true
        }
        guard now - lastTapBounceUptime >= TapResponse.cooldown else { return false }

        lastTapBounceUptime = now
        tapSequence &+= 1
        let activeTapSequence = tapSequence
        let bodyCount = CGFloat(impacts.count)
        let crowdScale = min(
            1,
            max(
                TapResponse.minimumCrowdEnergyScale,
                sqrt(TapResponse.fullEnergyBodyCount / bodyCount)
            )
        )
        var tapKicks: [UUID: TapKick] = [:]

        for (index, impact) in impacts.enumerated() {
            let pebble = impact.pebble
            guard let body = pebble.physicsBody else { continue }
            let localStrength = impact.strength
            let verticalJitter = deterministicVariation(
                for: pebble.descriptor.id,
                salt: index &* 2
            )
            let horizontalJitter = deterministicVariation(
                for: pebble.descriptor.id,
                salt: index &* 2 &+ 1
            )
            let desiredVerticalChange = max(
                0,
                (
                    TapResponse.peakVerticalVelocity
                        + TapResponse.verticalVariation * verticalJitter
                ) * crowdScale
                    * localStrength
            )
            let desiredVerticalVelocity = min(
                TapResponse.maximumVerticalVelocity,
                max(body.velocity.dy, 0) + desiredVerticalChange
            )
            let desiredHorizontalChange = (
                impact.horizontalDirection * TapResponse.peakRadialVelocity
                    + horizontalJitter * TapResponse.horizontalVariation
            ) * crowdScale * localStrength
            let desiredHorizontalVelocity = min(
                TapResponse.maximumHorizontalVelocity,
                max(
                    -TapResponse.maximumHorizontalVelocity,
                    body.velocity.dx + desiredHorizontalChange
                )
            )
            let desiredAngularVelocity = min(
                TapResponse.maximumAngularVelocity,
                max(
                    -TapResponse.maximumAngularVelocity,
                    body.angularVelocity + horizontalJitter * 1.8
                )
            )

            // SpriteKit can defer an impulse queued while an idle-paused scene
            // wakes up. Assigning the bounded velocity and clearing `isResting`
            // makes the first post-tap physics frame deterministic; collisions,
            // gravity, damping, and tilt still own every subsequent frame.
            body.isResting = false
            // The jar normally uses strong damping so hundreds of bodies settle
            // cheaply. Lower it only for this compact presentation arc; leaving
            // the resting value in place turns an 80 pt/s kick into a barely
            // perceptible two-point twitch on a real SpriteKit render loop.
            body.linearDamping = TapResponse.flightDamping
            body.usesPreciseCollisionDetection = true
            body.velocity = CGVector(
                dx: desiredHorizontalVelocity,
                dy: desiredVerticalVelocity
            )
            body.angularVelocity = desiredAngularVelocity
            tapKicks[pebble.descriptor.id] = TapKick(
                velocity: CGVector(
                    dx: desiredHorizontalVelocity,
                    dy: desiredVerticalVelocity
                ),
                angularVelocity: desiredAngularVelocity
            )

            // SpriteKit's intentionally gentle jar gravity would otherwise let
            // even a modest hop float for several seconds. A delayed physical
            // return impulse makes a compact trampoline arc: roughly a third
            // second up, then a decisive fall and settle, without teleporting.
            let returnSpeed = (
                TapResponse.baseReturnVelocity
                    + TapResponse.localReturnVelocity * localStrength
            ) * max(crowdScale, 0.72)
            scheduleTapReturn(
                for: pebble,
                sequence: activeTapSequence,
                returnSpeed: returnSpeed,
                delay: TapResponse.returnDelay,
                remainingFrameDeferrals: TapResponse.maximumReturnFrameDeferrals
            )
        }

        pendingTapKick = tapKicks.isEmpty ? nil : PendingTapKick(
            sequence: activeTapSequence,
            kicks: tapKicks,
            remainingFrames: TapResponse.reinforcementFrameCount
        )
        playTapCaustic(at: origin)
        soundSynth.playTick()
        haptics.playSecondaryCollision()
        return true
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
                  self.tapSequence == sequence,
                  let pebble,
                  pebble.parent != nil,
                  !pebble.isRemovedForBake,
                  let body = pebble.physicsBody
            else { return }

            if remainingFrameDeferrals > 0,
               let pendingTapKick = self.pendingTapKick,
               pendingTapKick.sequence == sequence,
               pendingTapKick.remainingFrames > 0,
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

            let desiredReturnVelocity = -returnSpeed
            if body.velocity.dy > desiredReturnVelocity {
                body.isResting = false
                body.linearDamping = TapResponse.settlingDamping
                body.velocity.dy = desiredReturnVelocity
            }

            DispatchQueue.main.asyncAfter(
                deadline: .now() + TapResponse.restoreDampingDelay
            ) { [weak self, weak pebble] in
                guard let self,
                      self.tapSequence == sequence,
                      let pebble,
                      pebble.parent != nil,
                      let body = pebble.physicsBody
                else { return }
                body.linearDamping = Constants.Jar.linearDamping
                body.usesPreciseCollisionDetection = !pebble.hasLanded
            }
        }
    }

    private func deterministicVariation(for id: UUID, salt: Int) -> CGFloat {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in id.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        hash ^= tapSequence &* 0x9E37_79B9_7F4A_7C15
        hash ^= UInt64(truncatingIfNeeded: salt) &* 0xBF58_476D_1CE4_E5B9
        return CGFloat(hash % 2_001) / 1_000 - 1
    }

    private func playTapCaustic(at point: CGPoint, expands: Bool = true) {
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
    func setGravityVector(_ proposed: CGVector, smoothing: Bool = true) {
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
        resumeSimulation()
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
        specularNode.position.x = fraction * 4
        backGlassNode.position.x = fraction * -1.6
        baseRefractionNode.position.x = fraction * 0.8
        lensShadeNode.position.x = fraction * -1.1
        mouthDepthNode.position.x = fraction * -0.55
        innerRimNode.position.x = fraction * 0.35
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
        updateIdlePause(currentTime: currentTime)
    }

    override func didSimulatePhysics() {
        super.didSimulatePhysics()
        reinforcePendingTapKickIfNeeded()
        livePebbles.forEach {
            $0.updatePresentationLighting(horizontal: opticalTiltFraction)
        }
    }

    /// A sleeping floor contact can consume a newly assigned upward velocity
    /// during the same SpriteKit step. Reassert the same bounded velocity for a
    /// handful of rendered frames so the tap reads as a hop instead of a twitch.
    /// The sequence is short, deterministic, and never mutates study records.
    private func reinforcePendingTapKickIfNeeded() {
        guard var pendingTapKick,
              pendingTapKick.sequence == tapSequence,
              !reduceMotion,
              pendingTapKick.remainingFrames > 0
        else {
            self.pendingTapKick = nil
            return
        }

        for pebble in livePebbles {
            guard let kick = pendingTapKick.kicks[pebble.descriptor.id],
                  !pebble.isRemovedForBake,
                  let body = pebble.physicsBody
            else { continue }
            body.isResting = false
            body.usesPreciseCollisionDetection = true
            body.linearDamping = TapResponse.flightDamping
            body.velocity = kick.velocity
            body.angularVelocity = kick.angularVelocity
        }

        pendingTapKick.remainingFrames -= 1
        self.pendingTapKick = pendingTapKick.remainingFrames > 0
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

        if !deliveredLanding, mutedLandingIDs.isEmpty { secondaryFeedback() }
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
        baseRefractionNode.name = "jar.glass.base"
        baseCausticNode.name = "jar.glass.baseCaustic"
        lensShadeNode.name = "jar.glass.lensShade"
        reducedMotionHighlightNode.name = "jar.reducedMotion.highlight"
        specularNode.name = "jar.glass.specular"
        warmReflectionNode.name = "jar.glass.warmReflection"
        rimNode.name = "jar.glass.rim"
        innerRimNode.name = "jar.glass.innerRim"
        tapCausticNode.name = "jar.tap.caustic"
        worldNode.addChild(jarShadowNode)
        worldNode.addChild(backGlassNode)
        worldNode.addChild(mouthDepthNode)
        worldNode.addChild(wallNode)
        worldNode.addChild(floorNode)
        worldNode.addChild(glassNode)
        worldNode.addChild(baseRefractionNode)
        worldNode.addChild(baseCausticNode)
        worldNode.addChild(lensShadeNode)
        worldNode.addChild(reducedMotionHighlightNode)
        worldNode.addChild(specularNode)
        worldNode.addChild(warmReflectionNode)
        worldNode.addChild(rimNode)
        worldNode.addChild(innerRimNode)
        worldNode.addChild(tapCausticNode)

        cameraNode.position = cameraRestPosition
        addChild(cameraNode)
        camera = cameraNode
        rebuildGeometry()
    }

    private func observeReduceMotion() {
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
        jarShadowNode.fillColor = UIColor.black.withAlphaComponent(0.42)
        jarShadowNode.strokeColor = .clear
        jarShadowNode.glowWidth = 18
        jarShadowNode.zPosition = JarZPosition.background - 2

        backGlassNode.path = jarPath
        backGlassNode.fillColor = JarPalette.backGlass
        backGlassNode.strokeColor = JarPalette.deepGlassEdge
        backGlassNode.lineWidth = 2.4
        backGlassNode.glowWidth = 0.8
        backGlassNode.zPosition = JarZPosition.background

        let mouthRect = CGRect(
            x: outer.minX + neckInset - 1,
            y: outer.maxY - 8,
            width: outer.width - neckInset * 2 + 2,
            height: 18
        )
        mouthDepthNode.path = CGPath(ellipseIn: mouthRect, transform: nil)
        mouthDepthNode.fillColor = JarPalette.mouthDepth
        mouthDepthNode.strokeColor = JarPalette.specular.withAlphaComponent(0.36)
        mouthDepthNode.lineWidth = 2.2
        mouthDepthNode.glowWidth = 1.0
        mouthDepthNode.zPosition = JarZPosition.background + 0.6

        glassNode.path = jarPath
        glassNode.fillColor = .white
        glassNode.fillTexture = Self.glassTexture(for: outer.size)
        // Keep the silhouette legible without letting a uniform blue halo win
        // over the mouth depth, base refraction, and asymmetric lens shading.
        // This is especially important against Dawn's brighter background.
        glassNode.strokeColor = JarPalette.glassEdge.withAlphaComponent(0.40)
        glassNode.lineWidth = 1.45
        glassNode.glowWidth = 0.22
        glassNode.zPosition = JarZPosition.glass

        let frontBaseArc = CGMutablePath()
        frontBaseArc.move(
            to: CGPoint(
                x: outer.minX + Constants.Jar.cornerRadius * 0.55,
                y: outer.minY + 12
            )
        )
        frontBaseArc.addQuadCurve(
            to: CGPoint(
                x: outer.maxX - Constants.Jar.cornerRadius * 0.55,
                y: outer.minY + 12
            ),
            control: CGPoint(x: outer.midX, y: outer.minY + 1.5)
        )
        baseRefractionNode.path = frontBaseArc
        baseRefractionNode.fillColor = .clear
        baseRefractionNode.strokeColor = JarPalette.glassEdge.withAlphaComponent(0.34)
        baseRefractionNode.lineWidth = 1.25
        baseRefractionNode.zPosition = JarZPosition.glass + 0.2

        baseCausticNode.path = CGPath(
            ellipseIn: CGRect(
                x: outer.midX - outer.width * 0.22,
                y: outer.minY + 5,
                width: outer.width * 0.44,
                height: 17
            ),
            transform: nil
        )
        baseCausticNode.fillColor = JarPalette.warmSpecular.withAlphaComponent(0.07)
        baseCausticNode.strokeColor = .clear
        baseCausticNode.lineWidth = 0
        baseCausticNode.glowWidth = 0
        baseCausticNode.zPosition = JarZPosition.glass + 0.32

        let lensShade = CGMutablePath()
        lensShade.move(to: CGPoint(x: outer.minX + 8, y: outer.minY + 38))
        lensShade.addCurve(
            to: CGPoint(x: outer.minX + neckInset + 7, y: outer.maxY - 15),
            control1: CGPoint(x: outer.minX + 4, y: outer.midY),
            control2: CGPoint(x: outer.minX + 11, y: outer.maxY - 58)
        )
        lensShade.move(to: CGPoint(x: outer.maxX - 8, y: outer.minY + 38))
        lensShade.addCurve(
            to: CGPoint(x: outer.maxX - neckInset - 7, y: outer.maxY - 15),
            control1: CGPoint(x: outer.maxX - 4, y: outer.midY),
            control2: CGPoint(x: outer.maxX - 11, y: outer.maxY - 58)
        )
        lensShadeNode.path = lensShade
        lensShadeNode.fillColor = .clear
        lensShadeNode.strokeColor = JarPalette.lensShade
        lensShadeNode.lineWidth = 14
        lensShadeNode.lineCap = .round
        lensShadeNode.glowWidth = 3.5
        lensShadeNode.alpha = 0.54
        lensShadeNode.zPosition = JarZPosition.glass + 0.42

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

        let highlights = CGMutablePath()
        highlights.move(to: CGPoint(x: outer.maxX - neckInset - 12, y: outer.maxY - 18))
        highlights.addCurve(
            to: CGPoint(x: outer.maxX - 13, y: outer.maxY - outer.height * 0.28),
            control1: CGPoint(x: outer.maxX - 14, y: outer.maxY - 54),
            control2: CGPoint(x: outer.maxX - 12, y: outer.maxY - outer.height * 0.18)
        )
        specularNode.path = highlights
        specularNode.fillColor = .clear
        specularNode.strokeColor = JarPalette.specular
        specularNode.lineWidth = 2.2
        specularNode.lineCap = .round
        specularNode.glowWidth = 0.8
        specularNode.alpha = 0.58
        specularNode.zPosition = JarZPosition.glass + 1

        let warmReflection = CGMutablePath()
        warmReflection.move(to: CGPoint(x: outer.minX + 15, y: outer.maxY - 48))
        warmReflection.addCurve(
            to: CGPoint(x: outer.minX + 11, y: outer.maxY - outer.height * 0.34),
            control1: CGPoint(x: outer.minX + 7, y: outer.maxY - 104),
            control2: CGPoint(x: outer.minX + 9, y: outer.maxY - outer.height * 0.24)
        )
        warmReflection.move(to: CGPoint(x: outer.midX - outer.width * 0.08, y: outer.maxY - 2))
        warmReflection.addCurve(
            to: CGPoint(x: outer.minX + neckInset + 9, y: outer.maxY - 9),
            control1: CGPoint(x: outer.midX - outer.width * 0.26, y: outer.maxY + 1),
            control2: CGPoint(x: outer.minX + neckInset + 4, y: outer.maxY - 2)
        )
        warmReflectionNode.path = warmReflection
        warmReflectionNode.fillColor = .clear
        warmReflectionNode.strokeColor = JarPalette.warmSpecular
        warmReflectionNode.lineWidth = 1.45
        warmReflectionNode.lineCap = .round
        warmReflectionNode.glowWidth = 1.0
        warmReflectionNode.alpha = 0.60
        warmReflectionNode.zPosition = JarZPosition.glass + 1.05

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
        rimNode.strokeColor = JarPalette.specular.withAlphaComponent(0.62)
        rimNode.lineWidth = 2.05
        rimNode.glowWidth = 0.65
        rimNode.zPosition = JarZPosition.glass + 1.2

        innerRimNode.path = CGPath(
            ellipseIn: mouthRect.insetBy(dx: 4.5, dy: 3.2),
            transform: nil
        )
        innerRimNode.fillColor = .clear
        innerRimNode.strokeColor = JarPalette.warmSpecular.withAlphaComponent(0.17)
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

    private static let glassTextureCache = NSCache<NSString, SKTexture>()

    private static func glassTexture(for size: CGSize) -> SKTexture {
        let pixelWidth = max(1, Int(size.width.rounded()))
        let pixelHeight = max(1, Int(size.height.rounded()))
        let key = NSString(string: "\(pixelWidth)x\(pixelHeight)")
        if let cached = glassTextureCache.object(forKey: key) { return cached }

        let renderSize = CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: renderSize, format: format).image { renderer in
            let context = renderer.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let horizontalColors = [
                JarPalette.warmSpecular.withAlphaComponent(0.12).cgColor,
                JarPalette.warmSpecular.withAlphaComponent(0.025).cgColor,
                UIColor.clear.cgColor,
                JarPalette.specular.withAlphaComponent(0.10).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: horizontalColors,
                locations: [0, 0.18, 0.72, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: renderSize.height * 0.45),
                    end: CGPoint(x: renderSize.width, y: renderSize.height * 0.55),
                    options: []
                )
            }

            let verticalColors = [
                UIColor.white.withAlphaComponent(0.07).cgColor,
                UIColor.clear.cgColor,
                UIColor(red: 0.10, green: 0.22, blue: 0.40, alpha: 0.10).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: verticalColors,
                locations: [0, 0.50, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: renderSize.width / 2, y: 0),
                    end: CGPoint(x: renderSize.width / 2, y: renderSize.height),
                    options: []
                )
            }

            // A narrow key-light ribbon and a cooler opposite rim create the
            // asymmetric highlights people read as thick, curved glass.
            context.saveGState()
            context.setBlendMode(.screen)
            let keyRibbon = [
                UIColor.clear.cgColor,
                JarPalette.warmSpecular.withAlphaComponent(0.14).cgColor,
                JarPalette.warmSpecular.withAlphaComponent(0.030).cgColor,
                UIColor.clear.cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: keyRibbon,
                locations: [0, 0.36, 0.58, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: renderSize.width * 0.03, y: renderSize.height / 2),
                    end: CGPoint(x: renderSize.width * 0.34, y: renderSize.height / 2),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
            context.restoreGState()

            let bottomCaustic = [
                UIColor(red: 0.32, green: 0.70, blue: 1, alpha: 0.12).cgColor,
                UIColor(red: 0.24, green: 0.48, blue: 0.88, alpha: 0.025).cgColor,
                UIColor.clear.cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: bottomCaustic,
                locations: [0, 0.44, 1]
            ) {
                context.drawRadialGradient(
                    gradient,
                    startCenter: CGPoint(
                        x: renderSize.width * 0.52,
                        y: renderSize.height * 0.94
                    ),
                    startRadius: 1,
                    endCenter: CGPoint(
                        x: renderSize.width * 0.52,
                        y: renderSize.height * 0.94
                    ),
                    endRadius: renderSize.width * 0.52,
                    options: [.drawsAfterEndLocation]
                )
            }

            // Microscopic deterministic grain keeps large translucent areas
            // from looking like a flat vector fill without requiring an asset.
            context.setFillColor(UIColor.white.withAlphaComponent(0.018).cgColor)
            for index in 0..<54 {
                let x = CGFloat((index * 73 + 19) % 997) / 997 * renderSize.width
                let y = CGFloat((index * 151 + 47) % 991) / 991 * renderSize.height
                let diameter = index.isMultiple(of: 3) ? CGFloat(0.9) : CGFloat(0.55)
                context.fillEllipse(in: CGRect(
                    x: x,
                    y: y,
                    width: diameter,
                    height: diameter
                ))
            }
        }
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        glassTextureCache.setObject(texture, forKey: key)
        return texture
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
    private func enqueue(_ descriptor: PebbleDescriptor, delay: TimeInterval) -> Bool {
        guard acceptedPebbleIDs.insert(descriptor.id).inserted else { return false }
        dropQueue.append(
            QueuedDrop(
                descriptor: descriptor,
                horizontalUnit: CGFloat.random(in: -1 ... 1),
                readyUptime: ProcessInfo.processInfo.systemUptime + delay,
                needsSpecialAnticipation: shouldShowSpecialAnticipation(for: descriptor)
            )
        )
        resumeSimulation()
        reportApproachingCapacity()
        return true
    }

    private func shouldShowSpecialAnticipation(for descriptor: PebbleDescriptor) -> Bool {
        if descriptor.isAchievement { return true }
        guard rareRewardMode.usesEnhancedPresentation else { return false }
        return descriptor.kind != .normal
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

        if physicalPebbleCount >= Constants.Jar.maxPhysicsBodies {
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
        spawn(next.descriptor, horizontalUnit: next.horizontalUnit)
        lastSpawnUptime = now
        _ = beginBakeIfNeeded(force: false)
    }

    private func spawn(_ descriptor: PebbleDescriptor, horizontalUnit: CGFloat) {
        let node = PebbleNode(
            descriptor: descriptor,
            reduceMotion: reduceMotion,
            rareRewardMode: rareRewardMode
        )
        if !reduceMotion {
            let xRange = interiorRect.width * Constants.Jar.dropHorizontalRangeFraction
            node.position = CGPoint(
                x: interiorRect.midX + min(max(horizontalUnit, -1), 1) * xRange,
                y: interiorRect.maxY - node.radius
            )
            node.physicsBody?.velocity = CGVector(
                dx: CGFloat.random(
                    in: -Constants.Jar.dropHorizontalSpeed ... Constants.Jar.dropHorizontalSpeed
                ),
                dy: Constants.Jar.dropVerticalSpeed
            )
            node.physicsBody?.angularVelocity = CGFloat.random(
                in: -Constants.Jar.dropHorizontalSpeed ... Constants.Jar.dropHorizontalSpeed
            )
        }
        worldNode.addChild(node)
        if reduceMotion {
            // SpriteKit wakes a body when it enters the scene graph. Apply the
            // settled state after insertion so it cannot render one active
            // physics frame before Reduce Motion takes effect.
            settleForReduceMotion(node)
        }
        publishPhysicalContentChangeIfNeeded()
        if reduceMotion {
            deliverReducedMotionLandingIfNeeded(for: node)
        }
        resetIdleObservation()
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
            persistenceHandler: persistenceHandler
        )
        selected.forEach { $0.markForBake() }
        publishPhysicalContentChangeIfNeeded()
        onCapacityEvent?(.bakeStarted(request))

        let finish: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.activeBake?.token == bakeToken else { return }
            selected.forEach { $0.removeFromParent() }
            let descriptor = request.outputDescriptor
            if !self.livePebbles.contains(where: { $0.descriptor.id == descriptor.id }) {
                _ = self.acceptedPebbleIDs.insert(descriptor.id)
                let aggregateNode = PebbleNode(
                    descriptor: descriptor,
                    reduceMotion: reduceMotion,
                    rareRewardMode: rareRewardMode
                )
                if !self.reduceMotion {
                    aggregateNode.position = CGPoint(
                        x: min(
                            max(
                                formationPoint.x,
                                self.interiorRect.minX + aggregateNode.radius
                            ),
                            self.interiorRect.maxX - aggregateNode.radius
                        ),
                        y: min(
                            max(
                                formationPoint.y,
                                self.currentFloorY + aggregateNode.radius
                            ),
                            self.interiorRect.maxY - aggregateNode.radius
                        )
                    )
                    aggregateNode.setScale(0.38)
                    aggregateNode.alpha = 0.25
                    aggregateNode.physicsBody?.velocity = CGVector(
                        dx: 0,
                        dy: Constants.Jar.aggregateBirthImpulse
                    )
                }
                self.worldNode.addChild(aggregateNode)
                if self.reduceMotion {
                    // As with a loose drop, scene insertion itself wakes the
                    // body. Settle only after the node belongs to the world.
                    self.settleForReduceMotion(aggregateNode)
                    self.deliverReducedMotionLandingIfNeeded(for: aggregateNode)
                } else {
                    aggregateNode.run(.group([
                        .scale(to: 1, duration: Constants.Jar.aggregateFormationDuration * 0.55),
                        .fadeIn(withDuration: Constants.Jar.aggregateFormationDuration * 0.55)
                    ]))
                    self.spawnSparks(
                        at: aggregateNode.position,
                        color: aggregateNode.subjectColor,
                        mark: "✦"
                    )
                }
            }
            self.publishPhysicalContentChangeIfNeeded()
            let persistenceHandler = self.activeBake?.persistenceHandler
            self.activeBake = nil
            self.isBakeInProgress = false
            persistenceHandler?(request)
            self.onCapacityEvent?(.bakeCompleted(request))
            self.resetIdleObservation()
            self.resumeSimulation()
        }

        if reduceMotion {
            finish()
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
                deadline: .now() + Constants.Jar.aggregateFormationDuration,
                execute: finish
            )
        }
        return true
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
        spawnDust(at: point, color: pebble.subjectColor)
        shakeCamera(impactSpeed: speed)

        switch pebble.descriptor.kind {
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
        if !pebble.descriptor.isAggregate {
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

    private func secondaryFeedback() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= suppressIncidentalFeedbackUntilUptime,
              now - lastSecondaryFeedbackUptime
                >= Constants.Sound.secondaryCollisionCooldown else { return }
        lastSecondaryFeedbackUptime = now
        soundSynth.playTick()
        haptics.playSecondaryCollision()
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
            switch descriptor.kind {
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
        herald.text = descriptor.kind == .prism ? "◇" : "✦"
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

    private func updateRareTwinkles() {
        guard !reduceMotion, rareRewardMode.usesEnhancedPresentation else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastTwinkleUptime >= Constants.Jar.rareTwinkleInterval else { return }
        lastTwinkleUptime = now
        for pebble in livePebbles {
            let probability: Double
            let mark: String
            let color: UIColor
            switch pebble.descriptor.kind {
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

    private func updateIdlePause(currentTime: TimeInterval) {
        // A failed aggregate may leave persisted-but-not-yet-rendered drops in
        // the queue. Let the visible chamber settle and pause while the explicit
        // retry UI is waiting instead of burning frames forever.
        guard (dropQueue.isEmpty || !suspendedAggregateIDs.isEmpty),
              !isBakeInProgress
        else {
            resetIdleObservation()
            return
        }
        guard let started = idleSampleStartedAt else {
            idleSampleStartedAt = currentTime
            livePebbles.forEach { $0.rememberObservedPosition() }
            return
        }
        guard currentTime - started >= Constants.Jar.idleWindow else { return }

        let movement = livePebbles.reduce(CGFloat.zero) { total, pebble in
            total + hypot(
                pebble.position.x - pebble.lastObservedPosition.x,
                pebble.position.y - pebble.lastObservedPosition.y
            )
        }
        if movement < Constants.Jar.idleMovementThreshold {
            livePebbles.forEach { pebble in
                pebble.physicsBody?.linearDamping = Constants.Jar.restingDamping
            }
            isIdlePaused = true
            onIdlePauseChanged?(true)
            isPaused = true
        } else {
            livePebbles.forEach { pebble in
                pebble.physicsBody?.linearDamping = Constants.Jar.linearDamping
                pebble.rememberObservedPosition()
            }
            idleSampleStartedAt = currentTime
        }
    }

    private func resetIdleObservation() {
        idleSampleStartedAt = nil
        livePebbles.forEach {
            $0.physicsBody?.linearDamping = Constants.Jar.linearDamping
            $0.rememberObservedPosition()
        }
    }

    /// Invalidates SwiftUI only when the live physics chamber transitions to a
    /// different body count. `physicalPebbleCount` itself remains computed from
    /// `livePebbles`, avoiding a second, potentially stale emptiness source.
    private func publishPhysicalContentChangeIfNeeded() {
        refreshEarlyEffortSpotlightsIfNeeded()
        let count = physicalPebbleCount
        guard count != lastPublishedPhysicalPebbleCount else { return }
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
            pebble.position.y = min(pebble.position.y, interiorRect.maxY - pebble.radius)
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

/// Turns device tilt into continuous SpriteKit gravity. There is no threshold
/// gesture: small hand movements immediately make every loose and aggregate
/// pebble shift, while the low-pass filter keeps the jar calm on a desk.
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

    func accepts(_ candidate: UInt64, reduceMotion: Bool) -> Bool {
        isActive && generation == candidate && !reduceMotion
    }
}

@MainActor
final class JarMotionObserver: ObservableObject {
    private let manager = CMMotionManager()
    private weak var scene: JarScene?
    private var updateGate = JarMotionUpdateGate()

    init(scene: JarScene? = nil) {
        self.scene = scene
    }

    func start(scene: JarScene? = nil) {
        if let scene { self.scene = scene }
        guard let targetScene = self.scene,
              !targetScene.reduceMotion,
              manager.isDeviceMotionAvailable,
              !manager.isDeviceMotionActive
        else { return }
        let generation = updateGate.begin()
        manager.deviceMotionUpdateInterval = 1 / TimeInterval(Constants.Jar.tiltUpdatesPerSecond)
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let gravity = motion?.gravity else { return }
            let horizontal = CGFloat(gravity.x) * Constants.Jar.tiltGravityHorizontalScale
            let sensedVertical = CGFloat(gravity.y) * abs(Constants.Jar.gravity)
            let vertical = min(-Constants.Jar.tiltGravityMinimumDownward, sensedVertical)
            Task { @MainActor [weak self] in
                guard let self,
                      let scene = self.scene,
                      self.updateGate.accepts(
                        generation,
                        reduceMotion: scene.reduceMotion
                      )
                else { return }
                scene.setGravityVector(
                    CGVector(dx: horizontal, dy: vertical)
                )
            }
        }
    }

    func stop() {
        // Invalidate before stopping/resetting so an update already queued on
        // MainActor cannot overwrite the stable downward gravity afterward.
        updateGate.invalidate()
        manager.stopDeviceMotionUpdates()
        scene?.resetGravity()
    }
}
