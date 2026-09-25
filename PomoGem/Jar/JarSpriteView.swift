import SpriteKit
import SwiftUI
import UIKit

enum JarMotionSamplingMode: Equatable {
    case stopped
    case tiltAndShake
}

enum JarMotionActivationPolicy {
    static func shouldCaptureShake(
        isMotionEnabled: Bool,
        sceneIsActive: Bool,
        hasPhysicalContent: Bool
    ) -> Bool {
        isMotionEnabled && sceneIsActive && hasPhysicalContent
    }

    static func shouldRun(
        isMotionEnabled: Bool,
        reduceMotion: Bool,
        sceneIsActive: Bool,
        hasPhysicalContent: Bool
    ) -> Bool {
        mode(
            isMotionEnabled: isMotionEnabled,
            reduceMotion: reduceMotion,
            sceneIsActive: sceneIsActive,
            hasPhysicalContent: hasPhysicalContent
        ) != .stopped
    }

    static func mode(
        isMotionEnabled: Bool,
        reduceMotion: Bool,
        sceneIsActive: Bool,
        hasPhysicalContent: Bool
    ) -> JarMotionSamplingMode {
        guard shouldCaptureShake(
            isMotionEnabled: isMotionEnabled,
            sceneIsActive: sceneIsActive,
            hasPhysicalContent: hasPhysicalContent
        ) else { return .stopped }
        // Reduce Motion changes decorative effects in the scene. The jar's
        // physical response to direct interaction remains the same.
        return .tiltAndShake
    }
}

/// Keeps the jar's spoken hierarchy aligned with the visible value hierarchy:
/// elapsed mass first, count-based storage second, and zero-mass achievements
/// as a separate record. This is pure so the ordering can be regression tested.
enum JarAccessibilityPresentation {
    static func value(
        totalGrams rawTotalGrams: Int,
        pebbleCount rawPebbleCount: Int,
        achievementCount rawAchievementCount: Int,
        aggregateCount rawAggregateCount: Int,
        legacyAggregateCount rawLegacyAggregateCount: Int = 0,
        representedPebbleCount rawRepresentedPebbleCount: Int,
        goldPebbleCount rawGoldPebbleCount: Int,
        prismPebbleCount rawPrismPebbleCount: Int,
        fusionProgressDescription: String?,
        projectionIsLowerBound: Bool,
        projectionIsUnverified: Bool = false,
        pendingMass: PendingMass? = nil,
        isCloudOfflineSession: Bool = false
    ) -> String {
        let totalGrams = max(0, rawTotalGrams)
        let pebbleCount = max(0, rawPebbleCount)
        let achievementCount = max(0, rawAchievementCount)
        let aggregateCount = max(0, rawAggregateCount)
        let legacyAggregateCount = max(0, rawLegacyAggregateCount)
        let representedPebbleCount = max(0, rawRepresentedPebbleCount)
        let goldPebbleCount = RareRewardPresentationPolicy.goldCount(
            rawGoldPebbleCount
        )
        let prismPebbleCount = RareRewardPresentationPolicy.prismCount(
            rawPrismPebbleCount
        )
        let aggregate = aggregateCount > 0
            ? "、まとまり粒\(aggregateCount)個、合計\(representedPebbleCount)粒分"
            : ""
        let legacyAggregate = legacyAggregateCount > 0
            ? "、旧形式のまとまり粒\(legacyAggregateCount)個（保存済み情報を確認できます）"
            : ""
        let fusion = projectionIsUnverified
            ? ""
            : (fusionProgressDescription.map { "、\($0)" } ?? "")
        let rare = [
            goldPebbleCount > 0 ? "金\(goldPebbleCount)粒" : nil,
            prismPebbleCount > 0 ? "虹\(prismPebbleCount)粒" : nil
        ].compactMap { $0 }.joined(separator: "、")
        let rareSuffix = rare.isEmpty ? "" : "、\(rare)"
        let massDescription: String
        if projectionIsUnverified {
            // sync-03 (icloud-life batch): say what the visible headline says
            // while iCloud is checked — the mass Home can stand behind, or
            // that the total follows once checked (`pendingMass` nil).
            let status = isCloudOfflineSession ? "このiPhoneの集計を確認中" : "iCloudを確認中"
            if let pendingMass {
                massDescription = "\(status)。この端末で確認済みの集中時間の質量：\(formattedMass(max(0, pendingMass.grams)))\(pendingMass.isLowerBound ? "以上" : "")"
            } else {
                massDescription = "\(status)。これまでの合計は確認が済むと表示します"
            }
        } else if projectionIsLowerBound {
            massDescription = "現在確認できた集中時間の質量：\(formattedMass(totalGrams))以上、集計整理中"
        } else {
            massDescription = "記録した集中時間の質量：\(formattedMass(totalGrams))"
        }
        return "\(massDescription)。瓶の整理：\(pebbleCount)粒\(aggregate)\(legacyAggregate)\(rareSuffix)\(fusion)。記念石\(achievementCount)個"
    }

    /// sync-03: the lifetime mass Home's headline shows while iCloud is
    /// checked (`PendingMassPresentationPolicy`).
    struct PendingMass: Equatable {
        let grams: Int
        let isLowerBound: Bool
    }

    private static func formattedMass(_ grams: Int) -> String {
        guard grams >= 1_000 else { return "\(grams)グラム" }
        return String(format: "%.2fキログラム", Double(grams) / 1_000)
    }
}

/// SwiftUI boundary for SpriteKit with an equivalent VoiceOver interaction.
struct JarSpriteView: View {
    @ObservedObject var scene: JarScene
    let totalGrams: Int
    let pebbleCount: Int
    let achievementCount: Int
    let aggregateCount: Int
    let legacyAggregateCount: Int
    let representedPebbleCount: Int
    let goldPebbleCount: Int
    let prismPebbleCount: Int
    let accentHex: String
    let lifetimeCoreColorHex: String
    let projectionIsLowerBound: Bool
    let projectionIsUnverified: Bool
    /// sync-03 (icloud-life): VoiceOver only; the jar's visuals are unchanged.
    let pendingMass: JarAccessibilityPresentation.PendingMass?
    let fusionProgressDescription: String?
    let isMotionEnabled: Bool
    let inspectableAggregateID: UUID?
    let onJarTapAccepted: (() -> Void)?
    let onAggregateTapped: ((UUID) -> Void)?
    let onAggregateAccessibilityAction: ((UUID) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.pomogemReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isCloudOfflineSession) private var isCloudOfflineSession
    @StateObject private var motionObserver: JarMotionObserver
#if targetEnvironment(macCatalyst)
    @State private var catalystGestureOwnership = JarDragGestureOwnership()
#endif

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    init(
        scene: JarScene,
        totalGrams: Int,
        pebbleCount: Int,
        achievementCount: Int = 0,
        aggregateCount: Int = 0,
        legacyAggregateCount: Int = 0,
        representedPebbleCount: Int? = nil,
        goldPebbleCount: Int = 0,
        prismPebbleCount: Int = 0,
        accentHex: String = Constants.Color.amberLamp,
        lifetimeCoreColorHex: String? = nil,
        projectionIsLowerBound: Bool = false,
        projectionIsUnverified: Bool = false,
        pendingMass: JarAccessibilityPresentation.PendingMass? = nil,
        fusionProgressDescription: String? = nil,
        isMotionEnabled: Bool = true,
        inspectableAggregateID: UUID? = nil,
        onJarTapAccepted: (() -> Void)? = nil,
        onAggregateTapped: ((UUID) -> Void)? = nil,
        onAggregateAccessibilityAction: ((UUID) -> Void)? = nil
    ) {
        _scene = ObservedObject(wrappedValue: scene)
        self.totalGrams = totalGrams
        self.pebbleCount = pebbleCount
        self.achievementCount = achievementCount
        self.aggregateCount = aggregateCount
        self.legacyAggregateCount = max(0, legacyAggregateCount)
        self.representedPebbleCount = representedPebbleCount ?? pebbleCount
        self.goldPebbleCount = RareRewardPresentationPolicy.goldCount(
            goldPebbleCount
        )
        self.prismPebbleCount = RareRewardPresentationPolicy.prismCount(
            prismPebbleCount
        )
        self.accentHex = accentHex
        self.lifetimeCoreColorHex = lifetimeCoreColorHex ?? accentHex
        self.projectionIsLowerBound = projectionIsLowerBound
        self.projectionIsUnverified = projectionIsUnverified
        self.pendingMass = pendingMass
        self.fusionProgressDescription = fusionProgressDescription
        self.isMotionEnabled = isMotionEnabled
        self.inspectableAggregateID = inspectableAggregateID
        self.onJarTapAccepted = onJarTapAccepted
        self.onAggregateTapped = onAggregateTapped
        self.onAggregateAccessibilityAction = onAggregateAccessibilityAction
        _motionObserver = StateObject(wrappedValue: JarMotionObserver(scene: scene))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                JarAmbientStage()

                let effortSnapshot = JarAccumulationPresencePresentation.effortSnapshot(
                    totalGrams: totalGrams
                )
                let accumulationPresence = JarAccumulationPresencePresentation.state(
                    totalGrams: totalGrams,
                    effortSnapshot: effortSnapshot
                )
                let shouldShowLifetimeCore = JarLifetimeCorePresentation.shouldShowCore(
                    totalPebbleCount: representedPebbleCount,
                    totalGrams: totalGrams
                )
                let lifetimeCoreState = shouldShowLifetimeCore
                    ? JarLifetimeCorePresentation.state(
                        totalPebbleCount: representedPebbleCount,
                        totalGrams: totalGrams,
                        projectionIsLowerBound: projectionIsLowerBound,
                        effortSnapshot: effortSnapshot
                    )
                    : nil

                if accumulationPresence.isVisible {
                    JarAccumulationPresenceBackdrop(
                        state: accumulationPresence,
                        colorHex: lifetimeCoreColorHex,
                        showsLifetimeCore: lifetimeCoreState != nil
                    )
                }

                if let coreState = lifetimeCoreState {
                    JarLifetimeCoreBackdrop(
                        state: coreState,
                        colorHex: lifetimeCoreColorHex
                    )
                }

                SpriteView(
                    scene: scene,
                    preferredFramesPerSecond: Constants.Jar.targetFramesPerSecond,
                    options: [.allowsTransparency]
                )
#if targetEnvironment(macCatalyst)
                // One zero-distance gesture owns both click and drag on Mac.
                // Once travel reaches 3 pt it can only be a tilt drag, so the
                // former 3...18 pt tap/drag double-fire cannot occur.
                .gesture(catalystInteractionGesture(
                    width: proxy.size.width,
                    height: proxy.size.height
                ))
#else
                // Own the iPhone tap at the SwiftUI boundary. Relying on
                // SpriteKit's UITouch forwarding beneath an accessibility
                // element can occasionally lose the touch end during a view
                // update. SpatialTapGesture preserves the exact local point
                // and gives the scene one deterministic input path.
                .contentShape(Rectangle())
                .highPriorityGesture(
                    SpatialTapGesture(coordinateSpace: .local)
                        .onEnded { value in
                            performSpatialTap(at: CGPoint(
                                x: value.location.x,
                                y: proxy.size.height - value.location.y
                            ))
                        }
                )
#endif
                .onAppear {
                    scene.size = proxy.size
                    updateMotionBehavior(reduceMotion: reduceMotion)
                }
                .onChange(of: proxy.size) { _, newSize in
                    scene.size = newSize
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("瓶")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(accessibilityHint)
        .modifier(JarAccessibilityInteractionModifier(
            scene: scene,
            isInteractive: hasPhysicalContent,
            aggregateID: inspectableAggregateID,
            onInspectAggregate:
                onAggregateAccessibilityAction ?? onAggregateTapped
        ))
        .onChange(of: reduceMotion) { _, enabled in
            updateMotionBehavior(reduceMotion: enabled)
        }
        .onChange(of: scenePhase) { _, _ in
            updateMotionBehavior(reduceMotion: reduceMotion)
        }
        .onChange(of: scene.physicalContentRevision) { _, _ in
            updateMotionBehavior(reduceMotion: reduceMotion)
        }
        .onChange(of: isMotionEnabled) { _, _ in
            updateMotionBehavior(reduceMotion: reduceMotion)
        }
#if !targetEnvironment(macCatalyst)
        .background {
            JarSystemShakeCapture(
                isEnabled: JarMotionActivationPolicy.shouldCaptureShake(
                    isMotionEnabled: isMotionEnabled,
                    sceneIsActive: scenePhase == .active,
                    hasPhysicalContent: hasPhysicalContent
                )
            ) {
                _ = scene.shakePebbles(
                    strength: Constants.Jar.systemShakeFallbackStrength,
                    horizontal: 0
                )
            }
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
        }
#endif
        .onDisappear {
            scene.cancelInteractionPresentation()
            motionObserver.stop()
        }
    }

    private var accessibilityValue: String {
        let studyValue = JarAccessibilityPresentation.value(
            totalGrams: totalGrams,
            pebbleCount: pebbleCount,
            achievementCount: achievementCount,
            aggregateCount: aggregateCount,
            legacyAggregateCount: legacyAggregateCount,
            representedPebbleCount: representedPebbleCount,
            goldPebbleCount: goldPebbleCount,
            prismPebbleCount: prismPebbleCount,
            fusionProgressDescription: fusionProgressDescription,
            projectionIsLowerBound: projectionIsLowerBound,
            projectionIsUnverified: projectionIsUnverified,
            pendingMass: pendingMass,
            isCloudOfflineSession: isCloudOfflineSession
        )
        guard let obstacles = scene.screenTimeObstacleAccessibilityDescription else {
            return studyValue
        }
        return "\(studyValue)、\(obstacles)"
    }

    private var accessibilityHint: String {
        guard hasPhysicalContent else {
            return "まだ粒はありません。集中を完走するか成果を積むと、瓶に粒が入ります"
        }
#if targetEnvironment(macCatalyst)
        let base = "瓶をクリックすると粒が跳ねます。左右にドラッグするか、VoiceOverのカスタムアクションでも粒を動かせます"
#else
        let base = "瓶をタップすると数秒だけ1粒が大きく跳ね、ぶつかった周囲の粒も自然に動いて止まります。その間はiPhoneを傾けたり、軽く振ったりして動かせます"
#endif
        guard inspectableAggregateID != nil else { return base }
        return "\(base)。「最新のまとまり粒の内訳を見る」アクションで、保存されている粒数や質量などを確認できます"
    }

    private func performSpatialTap(at point: CGPoint) {
        guard scene.bouncePebbles(at: point) else { return }
        onJarTapAccepted?()
        guard let aggregateID = scene.lastAcceptedTapSelection?
            .inspectableAggregateID
        else { return }
        onAggregateTapped?(aggregateID)
    }

    /// One physical source of truth covers loose pebbles, aggregates,
    /// achievement stones, and migrated strata alike.
    var hasPhysicalContent: Bool {
        scene.physicalPebbleCount > 0
    }

    @MainActor
    private func updateMotionBehavior(reduceMotion: Bool) {
        scene.reduceMotion = reduceMotion
        if scenePhase != .active {
            scene.cancelInteractionPresentation()
        }
#if targetEnvironment(macCatalyst)
        // Catalyst has no device tilt. Drag and accessibility actions are the
        // explicit input paths, while stop restores stable downward gravity.
        motionObserver.stop()
#else
        let samplingMode = JarMotionActivationPolicy.mode(
            isMotionEnabled: isMotionEnabled,
            reduceMotion: reduceMotion,
            sceneIsActive: scenePhase == .active,
            hasPhysicalContent: hasPhysicalContent
        )
        switch samplingMode {
        case .stopped:
            scene.cancelInteractionPresentation()
            // `stop` also restores the scene's default downward gravity. This
            // matters when interaction, app lifecycle, or an empty bottle no
            // longer needs the sensor while a prior tilt is still applied.
            motionObserver.stop()
        case .tiltAndShake:
            motionObserver.start(scene: scene, appliesGravity: true)
        }
#endif
    }

#if targetEnvironment(macCatalyst)
    private func catalystInteractionGesture(width: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let distance = hypot(value.translation.width, value.translation.height)
                var ownership = catalystGestureOwnership
                let ownsDrag = ownership.observe(distance: distance)
                catalystGestureOwnership = ownership
                guard ownsDrag else { return }
                let travel = max(width * 0.22, 1)
                let horizontalFraction = min(
                    max(value.translation.width / travel, -1),
                    1
                )
                scene.setGravityVector(
                    CGVector(
                        dx: horizontalFraction * Constants.Jar.tiltGravityHorizontalScale,
                        dy: Constants.Jar.gravity
                    ),
                    smoothing: false,
                    wakesSimulation: true
                )
            }
            .onEnded { value in
                let distance = hypot(value.translation.width, value.translation.height)
                var ownership = catalystGestureOwnership
                let wasDrag = ownership.finish(distance: distance)
                catalystGestureOwnership = ownership
                if wasDrag {
                    // A drag owns the entire gesture once the threshold has
                    // ever been crossed, even if the pointer returns to origin.
                    scene.resetGravity()
                } else {
                    performSpatialTap(at: CGPoint(
                        x: value.location.x,
                        y: height - value.location.y
                    ))
                }
            }
    }
#endif
}

#if !targetEnvironment(macCatalyst)
/// UIKit's system shake event is a resilient fallback for short acceleration
/// peaks that Core Motion sampling can miss under a busy SpriteKit frame. The
/// system path fires at motion-begin (not motion-end) to keep both detections
/// inside JarScene's shared cooldown in normal use.
///
/// The shake is picked up where UIKit delivers it when nothing on screen is
/// first responder: the window (see the `UIWindow` extension below). This view
/// only tells the window which jar is in it and whether that jar wants shakes.
/// It must never claim first responder itself. It used to, and while it held
/// it, opening Home's theme or duration `Menu` let iOS 26's menu type-select
/// attach its key input to it; wherever UIKit reports a hardware keyboard as
/// available while the software keyboard is in use (the iOS Simulator by
/// default), a full software keyboard then covered the lower half of the menu.
private struct JarSystemShakeCapture: UIViewRepresentable {
    let isEnabled: Bool
    let onShake: @MainActor () -> Void

    func makeUIView(context: Context) -> ShakeObserverView {
        ShakeObserverView()
    }

    func updateUIView(_ uiView: ShakeObserverView, context: Context) {
        uiView.onShake = onShake
        uiView.acceptsShake = isEnabled
    }

    static func dismantleUIView(_ uiView: ShakeObserverView, coordinator: ()) {
        uiView.acceptsShake = false
        uiView.onShake = nil
    }

    @MainActor
    final class ShakeObserverView: UIView {
        var onShake: (@MainActor () -> Void)?
        var acceptsShake = false

        private static let attached = NSHashTable<ShakeObserverView>.weakObjects()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                Self.attached.remove(self)
            } else {
                Self.attached.add(self)
            }
        }

        /// Hands a shake that reached `window` to the jars in it that accept
        /// one. Returns whether any did, so the window can keep the event, as
        /// the old first-responder view did.
        static func deliverShake(in window: UIWindow) -> Bool {
            var delivered = false
            for view in attached.allObjects
            where view.window === window && view.acceptsShake {
                view.onShake?()
                delivered = true
            }
            return delivered
        }
    }
}

extension UIWindow {
    /// Motion events go to the first responder and up its chain, and to the
    /// key window when nothing is first responder, so every shake passes
    /// through here unless a responder below handles it first. UIWindow does
    /// not implement this method itself, so this adds the window's override
    /// rather than replacing UIKit's; unhandled shakes continue to `super`.
    override open func motionBegan(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake,
           JarSystemShakeCapture.ShakeObserverView.deliverShake(in: self) {
            return
        }
        super.motionBegan(motion, with: event)
    }
}
#endif

/// Monotonic gesture ownership shared with focused tests. Once a pointer has
/// crossed the drag threshold, travelling back cannot turn that gesture into a
/// tap; `finish` also resets the state for the next interaction.
struct JarDragGestureOwnership {
    private(set) var exceededThreshold = false

    mutating func observe(distance: CGFloat, threshold: CGFloat = 3) -> Bool {
        if distance >= threshold {
            exceededThreshold = true
        }
        return exceededThreshold
    }

    mutating func finish(distance: CGFloat, threshold: CGFloat = 3) -> Bool {
        let wasDrag = observe(distance: distance, threshold: threshold)
        exceededThreshold = false
        return wasDrag
    }
}

/// Empty jars remain informative static elements. Once at least one pebble
/// exists, the exact same visual gains button semantics and VoiceOver actions.
private struct JarAccessibilityInteractionModifier: ViewModifier {
    let scene: JarScene
    let isInteractive: Bool
    let aggregateID: UUID?
    let onInspectAggregate: ((UUID) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isInteractive {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    performBounce()
                }
                .accessibilityAction(named: "瓶の粒を動かす") {
                    performBounce()
                }
                .modifier(JarDirectionalAccessibilityModifier(scene: scene))
                .modifier(JarAggregateAccessibilityModifier(
                    aggregateID: aggregateID,
                    onInspectAggregate: onInspectAggregate
                ))
        } else {
            content
        }
    }

    private func performBounce() {
        guard scene.bouncePebbles() else { return }
        UIAccessibility.post(
            notification: .announcement,
            argument: "瓶の粒が跳ねました"
        )
    }
}

private struct JarAggregateAccessibilityModifier: ViewModifier {
    let aggregateID: UUID?
    let onInspectAggregate: ((UUID) -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let aggregateID, let onInspectAggregate {
            content
                .accessibilityAction(named: "最新のまとまり粒の内訳を見る") {
                    onInspectAggregate(aggregateID)
                }
        } else {
            content
        }
    }
}

private struct JarDirectionalAccessibilityModifier: ViewModifier {
    let scene: JarScene

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: "瓶の粒を左へ動かす") {
                scene.nudge(horizontal: -1)
            }
            .accessibilityAction(named: "瓶の粒を右へ動かす") {
                scene.nudge(horizontal: 1)
            }
    }
}

/// Code-native light rig behind the SpriteKit bottle. Static gradients and a
/// single Canvas-style scene avoid another animation loop while giving the
/// transparent jar a clear foreground, midground, and ground plane.
private struct JarAmbientStage: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack(alignment: .bottom) {
                RadialGradient(
                    colors: [
                        PomoGemTheme.auroraWarm.opacity(reduceTransparency ? 0.035 : 0.085),
                        PomoGemTheme.auroraViolet.opacity(reduceTransparency ? 0.025 : 0.065),
                        .clear
                    ],
                    center: UnitPoint(x: 0.48, y: 0.48),
                    startRadius: 4,
                    endRadius: max(width, height) * 0.56
                )
                .frame(width: width * 1.14, height: height * 0.92)
                .offset(y: -height * 0.03)

                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                PomoGemTheme.auroraBlue.opacity(reduceTransparency ? 0.08 : 0.18),
                                Color.black.opacity(0.46),
                                .clear
                            ],
                            center: .center,
                            startRadius: 2,
                            endRadius: width * 0.42
                        )
                    )
                    .frame(width: width * 0.86, height: max(30, height * 0.10))
                    .blur(radius: reduceTransparency ? 4 : 10)
                    .offset(y: -height * 0.035)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
