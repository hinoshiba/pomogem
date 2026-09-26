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
        hasStudyGems: Bool
    ) -> Bool {
        mode(
            isMotionEnabled: isMotionEnabled,
            reduceMotion: reduceMotion,
            sceneIsActive: sceneIsActive,
            hasStudyGems: hasStudyGems
        ) != .stopped
    }

    /// The sensor runs only for a visible, active jar (Home in front:
    /// no covering sheet, not the Focus screen) that holds a study gem.
    /// Whether it runs at the full or the idle rate is the jar's own
    /// demand (`JarMotionRate`).
    static func mode(
        isMotionEnabled: Bool,
        reduceMotion: Bool,
        sceneIsActive: Bool,
        hasStudyGems: Bool
    ) -> JarMotionSamplingMode {
        guard isMotionEnabled, sceneIsActive, hasStudyGems else { return .stopped }
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
            massDescription = isCloudOfflineSession
                ? "このiPhoneの集計を確認中。確認できた粒を表示"
                : "iCloudの集計を再確認中。この端末で確認できた粒を表示"
        } else if projectionIsLowerBound {
            massDescription = "現在確認できた集中時間の質量：\(formattedMass(totalGrams))以上、集計整理中"
        } else {
            massDescription = "記録した集中時間の質量：\(formattedMass(totalGrams))"
        }
        return "\(massDescription)。瓶の整理：\(pebbleCount)粒\(aggregate)\(legacyAggregate)\(rareSuffix)\(fusion)。記念石\(achievementCount)個"
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
    let lifetimeCoreColorShares: [GemColorShare]
    /// Height of an overlaid HUD at the top of the stage (Home), so the core
    /// and its orbit stay clear of it.
    let coreTopClearance: CGFloat?
    let projectionIsLowerBound: Bool
    let projectionIsUnverified: Bool
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
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    /// 演出の強さ (D17): device-local, read live from Settings.
    @AppStorage(JarEffectsIntensity.defaultsKey) private var effectsIntensity: JarEffectsIntensity = .standard
    @StateObject private var motionObserver: JarMotionObserver
    /// Measured size of the time core's label block (shared by the core
    /// behind the scene and its labels in front, so both use one layout;
    /// the width tells which columns of the pile lie under the labels).
    @State private var coreLabelMetrics = JarLifetimeCoreLabelMetrics.estimated
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
        lifetimeCoreColorShares: [GemColorShare] = [],
        coreTopClearance: CGFloat? = nil,
        projectionIsLowerBound: Bool = false,
        projectionIsUnverified: Bool = false,
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
        self.lifetimeCoreColorShares = lifetimeCoreColorShares
        self.coreTopClearance = coreTopClearance
        self.projectionIsLowerBound = projectionIsLowerBound
        self.projectionIsUnverified = projectionIsUnverified
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

                // The core column (orbit and labels) stays above the gem
                // bed, which the scene draws in front of this layer.
                let bedTop = JarScene.gemBedTopFromStageTop(
                    stageSize: proxy.size,
                    bed: gemBedState
                )
                let coreBottomLimit = bedTop - 6
                let limits = JarLifetimeCoreLabelLimits.resolve(
                    stageHeight: proxy.size.height,
                    floorY: JarScene.interiorRect(sceneSize: proxy.size).minY,
                    bedTop: bedTop,
                    pileTop: scene.settledPileTop(
                        minX: (proxy.size.width - coreLabelMetrics.size.width) / 2,
                        maxX: (proxy.size.width + coreLabelMetrics.size.width) / 2
                    )
                )
                let floorLabelLimit = limits.floor
                let abovePileLimit = limits.abovePile
                // Round 12: the column is placed from the HUD, the bed and
                // the floor row only, so the core never moves or shrinks
                // with the pile (the pile scale keeps the pile below it,
                // `JarScene.pileClearances`). The labels then show whole,
                // without the second line, or not at all, whichever fits
                // above the settled gems (the completion card shortens the
                // jar the same way).
                let coreSecondLine = lifetimeCoreState?.nextFusionLabel == nil ? 0 : coreLabelMetrics.secondLine
                let coreLabelHeight = coreLabelMetrics.size.height
                let coreLabelBottomLimit = floorLabelLimit
                let coreLayout = lifetimeCoreState.map { state in
                    JarLifetimeCoreLabels.layout(
                        stageSize: proxy.size,
                        state: state,
                        topClearance: coreTopClearance,
                        bottomLimit: coreBottomLimit,
                        labelBottomLimit: coreLabelBottomLimit,
                        labelHeight: coreLabelHeight
                    )
                }
                let namePlateHalfWidth = coreLabelMetrics.namePlateWidth / 2 + JarLifetimeCoreLabelLimits.clearance
                let nameAbovePileLimit = JarLifetimeCoreLabelLimits.resolve(
                    stageHeight: proxy.size.height,
                    floorY: JarScene.interiorRect(sceneSize: proxy.size).minY,
                    bedTop: bedTop,
                    pileTop: scene.settledPileTop(
                        minX: proxy.size.width / 2 - namePlateHalfWidth,
                        maxX: proxy.size.width / 2 + namePlateHalfWidth
                    )
                ).abovePile
                let coreLabelFit = coreLayout.map { layout in
                    JarLifetimeCoreLabelFit.resolve(
                        fullHeight: coreLabelMetrics.size.height,
                        secondLineHeight: coreSecondLine,
                        nameHeight: coreLabelMetrics.namePlate,
                        abovePileLimit: abovePileLimit,
                        nameAbovePileLimit: nameAbovePileLimit
                    ) { _ in layout }
                } ?? .full
                let coreLabelsBuried = coreLabelFit == .hidden
                let coreDisc = Self.coreDisc(
                    stageSize: proxy.size,
                    coreState: lifetimeCoreState,
                    coreLayout: coreLayout,
                    totalGrams: totalGrams,
                    topClearance: coreTopClearance,
                    bottomLimit: coreBottomLimit,
                    labelBottomLimit: coreLabelBottomLimit
                )
                // A pile the scale could not keep down (a heavy jar at
                // 1.0, or a young one at the 2.0 floor) never buries the
                // core: it steps in front of the settled gems instead.
                let coreInFront = coreDisc.map { disc in
                    scene.settledPileTop(minX: disc.center.x - disc.radius, maxX: disc.center.x + disc.radius)
                        > proxy.size.height - disc.center.y - disc.radius * 0.8
                } ?? false
                let pileClearances = Self.pileClearances(
                    stageSize: proxy.size,
                    coreDisc: coreDisc,
                    namePlate: coreLayout.map { layout in
                        (top: layout.labelTop, height: coreLabelMetrics.namePlate, halfWidth: namePlateHalfWidth)
                    },
                    hudBottom: coreTopClearance
                )
                let effects = JarEffectsIntensity.resolved(preference: effectsIntensity, reduceMotion: reduceMotion)
                let shareCore = Self.shareCore(
                    stageSize: proxy.size,
                    coreState: lifetimeCoreState,
                    totalGrams: totalGrams,
                    shares: lifetimeCoreColorShares.isEmpty
                        ? [GemColorShare(hex: lifetimeCoreColorHex, fraction: 1)]
                        : lifetimeCoreColorShares,
                    themeMarks: GemThemeMark.isEnabled(environment: differentiateWithoutColor),
                    effects: effects
                )
                if let coreState = lifetimeCoreState {
                    // Behind the scene: all of it, or (when the pile reaches
                    // the core) its bloom and orbit, the stone in front.
                    JarLifetimeCoreBackdrop(
                        state: coreState,
                        colorHex: lifetimeCoreColorHex,
                        colorShares: lifetimeCoreColorShares,
                        topClearance: coreTopClearance,
                        bottomLimit: coreBottomLimit,
                        labelBottomLimit: coreLabelBottomLimit,
                        labelHeight: coreLabelHeight,
                        effectsInEffect: effects,
                        parts: coreInFront ? .behindThePile : .whole
                    )
                    // The whole block, laid out but never drawn, measures
                    // the labels (their measured size keeps the layout
                    // stable whatever shows). Labels the pile would reach
                    // are not drawn at all: behind the large gems of a young
                    // jar (D4) only fragments of text would show through
                    // the gaps. VoiceOver reads the jar as one element.
                    JarLifetimeCoreLabels(
                        state: coreState,
                        topClearance: coreTopClearance,
                        bottomLimit: coreBottomLimit,
                        labelBottomLimit: coreLabelBottomLimit,
                        metrics: $coreLabelMetrics
                    )
                    .opacity(0)
                } else if totalGrams > 0, totalGrams < GemCutLadder.firstCrystalTierGrams, !coreInFront {
                    // Where the core will be born: a colourless vessel whose
                    // facets light up one per 250 g.
                    JarLifetimeCoreVessel(
                        totalGrams: totalGrams,
                        topClearance: coreTopClearance,
                        bottomLimit: coreBottomLimit,
                        labelBottomLimit: coreLabelBottomLimit,
                        effectsInEffect: effects
                    )
                }

                // jar-01: the scene stops this SKView's render loop itself
                // while it rests (`JarScene.isRenderLoopPaused`), because
                // SpriteView applies `isPaused` only when it creates the view.
                SpriteView(
                    scene: scene,
                    // Low Power Mode and a hot device drop to 30 fps (the
                    // flares and event sparks also pause there).
                    preferredFramesPerSecond: JarScene.allowsAmbientSparkle
                        ? Constants.Jar.targetFramesPerSecond
                        : min(30, Constants.Jar.targetFramesPerSecond),
                    options: [.allowsTransparency, .ignoresSiblingOrder, .shouldCullNonVisibleNodes],
                    debugOptions: Self.spriteDebugOptions
                )
                // The scene's light (gem halos, the first gems' bloom, the
                // floor and pile light) reaches past the bottle; it fades
                // out before the SKView's edge instead of being cut there
                // in a visible rectangle (round 12).
                .mask {
                    Image(uiImage: JarLightBounds.image(stageSize: proxy.size))
                        .resizable()
                }
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
#if DEBUG && targetEnvironment(simulator)
                    JarFrameProbe.shared?.attach(scene)
#endif
                    scene.size = proxy.size
                    scene.artworkScale = displayScale
                    scene.gemBed = gemBedState
                    scene.milestoneTraceCount = milestoneTraceCount
                    scene.effectsIntensity = effectsIntensity
                    updateMotionBehavior(reduceMotion: reduceMotion)
                    // Home shown again: draw the resting jar's frame.
                    scene.requestRedraw()
                }
                .onChange(of: effectsIntensity) { _, intensity in
                    scene.effectsIntensity = intensity
                }
                .onChange(of: milestoneTraceCount) { _, count in
                    scene.milestoneTraceCount = count
                }
                .onChange(of: gemBedState) { _, state in
                    scene.gemBed = state
                }
                .onChange(of: shareCore, initial: true) { _, core in
                    scene.shareCore = core
                }
                .onChange(of: pileClearances, initial: true) { _, clearances in
                    scene.pileClearances = clearances
                }
                .onChange(of: proxy.size) { _, newSize in
                    scene.size = newSize
                }

                if coreInFront {
                    if let coreState = lifetimeCoreState {
                        JarLifetimeCoreBackdrop(
                            state: coreState,
                            colorHex: lifetimeCoreColorHex,
                            colorShares: lifetimeCoreColorShares,
                            topClearance: coreTopClearance,
                            bottomLimit: coreBottomLimit,
                            labelBottomLimit: coreLabelBottomLimit,
                            labelHeight: coreLabelHeight,
                            effectsInEffect: effects,
                            parts: .inFrontOfThePile
                        )
                    } else {
                        JarLifetimeCoreVessel(
                            totalGrams: totalGrams,
                            topClearance: coreTopClearance,
                            bottomLimit: coreBottomLimit,
                            labelBottomLimit: coreLabelBottomLimit,
                            effectsInEffect: effects
                        )
                    }
                }

                // The core's name plate and progress card sit in front of
                // the scene (like the HUD): the bed can never hide them, and
                // they may overlap its soft top edge.
                if let coreState = lifetimeCoreState, !coreLabelsBuried {
                    JarLifetimeCoreLabels(
                        state: coreState,
                        topClearance: coreTopClearance,
                        bottomLimit: coreBottomLimit,
                        labelBottomLimit: coreLabelBottomLimit,
                        fit: coreLabelFit,
                        measures: false,
                        metrics: $coreLabelMetrics
                    )
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
        .onChange(of: scenePhase) { _, phase in
            updateMotionBehavior(reduceMotion: reduceMotion)
            // Back in front: redraw the resting jar (the system may have
            // dropped its drawable), then its render loop stops again.
            if phase == .active { scene.requestRedraw() }
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
        // The stage light lies behind the whole jar but outside its
        // accessibility element: its glow is wider than the stage and its
        // floor light runs past the bottom edge, and inside the element those
        // bounds became the jar's frame, so VoiceOver's jar reached over the
        // theme row and a tap placed in that frame missed the gem.
        .background {
            JarAmbientStage()
        }
        .onDisappear {
            scene.cancelInteractionPresentation()
            motionObserver.stop()
        }
    }

    /// 「積み上がりの光」 as a gem bed: lifetime grams and the lifetime theme
    /// mix only (the same fan as the time core). While the projection is
    /// provisional (unverified or a lower bound) the bed never sinks below
    /// the one already shown.
    private var gemBedState: JarGemBedState {
        JarGemBedPresentation.displayed(
            current: JarGemBedPresentation.state(
                totalGrams: totalGrams,
                colorShares: lifetimeCoreColorShares.isEmpty
                    ? [GemColorShare(hex: lifetimeCoreColorHex, fraction: 1)]
                    : lifetimeCoreColorShares
            ),
            shown: scene.gemBed,
            isProvisional: projectionIsLowerBound || projectionIsUnverified
        )
    }

    /// Where the time core (or, before 2.5 kg, its vessel) is drawn: its
    /// centre in stage coordinates (y down) and the drawn stone's radius.
    private static func coreDisc(
        stageSize: CGSize,
        coreState: JarLifetimeCoreState?,
        coreLayout: JarLifetimeCoreLayout?,
        totalGrams: Int,
        topClearance: CGFloat?,
        bottomLimit: CGFloat,
        labelBottomLimit: CGFloat
    ) -> (center: CGPoint, radius: CGFloat)? {
        let jarWidth = max(1, stageSize.width - Constants.Jar.horizontalMargin * 2)
        if let coreState, let coreLayout {
            let core = JarLifetimeCoreBackdrop.coreDiameter(jarWidth: jarWidth, level: coreState.coreLevel)
            return (
                CGPoint(x: stageSize.width / 2, y: coreLayout.centerY),
                core * coreLayout.stoneScale * JarLifetimeCoreLayout.stoneRadiusFactor
            )
        }
        guard totalGrams > 0, totalGrams < GemCutLadder.firstCrystalTierGrams else { return nil }
        let core = JarLifetimeCoreBackdrop.coreDiameter(jarWidth: jarWidth, level: 1)
        let layout = JarLifetimeCoreLayout.resolve(
            stageHeight: stageSize.height,
            core: core,
            orbitCount: 1,
            topClearance: topClearance,
            bottomLimit: bottomLimit,
            labelBottomLimit: labelBottomLimit,
            labelHeight: JarLifetimeCoreBackdrop.estimatedLabelHeight,
            minimumStoneDiameter: JarLifetimeCoreBackdrop.minimumStoneDiameter(jarWidth: jarWidth)
        )
        // The vessel is drawn at 0.92 of the core frame.
        return (
            CGPoint(x: stageSize.width / 2, y: layout.centerY),
            core * 0.92 * JarLifetimeCoreLayout.stoneRadiusFactor
        )
    }

    /// Where the settled pile must stay below (scene coordinates, y up),
    /// for the pile scale (`JarScene.pileClearances`, round 12):
    /// - under the core, no higher than 0.45 of its radius below its
    ///   centre, so at least about 85 % of the stone shows; the scale never
    ///   gives way below 2.0 for it;
    /// - under the core's name plate (its width and 6 pt), 6 pt below it,
    ///   so a young jar keeps 「時間の核」 readable, but only when two rungs
    ///   smaller gems clear it (large gems come first; out of reach, the
    ///   plate hides instead);
    /// - under the Home HUD's value (its central 200 pt), 8 pt below its
    ///   measured bottom, down to scale 1.0 (the completion card shortens
    ///   the jar under a HUD that stays put).
    static func pileClearances(
        stageSize: CGSize,
        coreDisc: (center: CGPoint, radius: CGFloat)?,
        namePlate: (top: CGFloat, height: CGFloat, halfWidth: CGFloat)? = nil,
        hudBottom: CGFloat?
    ) -> [JarPileClearance] {
        guard stageSize.width > 0, stageSize.height > 0 else { return [] }
        var clearances: [JarPileClearance] = []
        if let disc = coreDisc, disc.radius > 0 {
            clearances.append(JarPileClearance(
                minX: disc.center.x - disc.radius,
                maxX: disc.center.x + disc.radius,
                ceiling: (stageSize.height - disc.center.y - disc.radius * 0.45).rounded(),
                minimumScale: JarPileClearance.coreMinimumScale
            ))
        }
        if let plate = namePlate, plate.height > 0, plate.halfWidth > 0 {
            clearances.append(JarPileClearance(
                minX: stageSize.width / 2 - plate.halfWidth,
                maxX: stageSize.width / 2 + plate.halfWidth,
                ceiling: (stageSize.height - plate.top - plate.height - JarLifetimeCoreLabelLimits.clearance).rounded(),
                minimumScale: JarPileClearance.namePlateMinimumScale,
                isOptional: true
            ))
        }
        if let hudBottom, hudBottom > 0 {
            clearances.append(JarPileClearance(
                minX: stageSize.width / 2 - JarPileClearance.hudHalfWidth,
                maxX: stageSize.width / 2 + JarPileClearance.hudHalfWidth,
                ceiling: (stageSize.height - hudBottom - 8).rounded(),
                minimumScale: JarScalePolicy.minimumScale
            ))
        }
        return clearances
    }

    /// The centrepiece a share snapshot redraws behind the bottle.
    private static func shareCore(
        stageSize: CGSize,
        coreState: JarLifetimeCoreState?,
        totalGrams: Int,
        shares: [GemColorShare],
        themeMarks: Bool,
        effects: JarEffectsIntensity
    ) -> JarShareCore? {
        let jarWidth = max(1, stageSize.width - Constants.Jar.horizontalMargin * 2)
        if let coreState {
            return JarShareCore(
                shares: shares,
                level: coreState.coreLevel,
                vesselLitFacets: nil,
                diameter: JarLifetimeCoreBackdrop.coreDiameter(jarWidth: jarWidth, level: coreState.coreLevel),
                themeMarks: themeMarks,
                effects: effects
            )
        }
        guard totalGrams > 0, totalGrams < GemCutLadder.firstCrystalTierGrams else { return nil }
        return JarShareCore(
            shares: [],
            level: 0,
            vesselLitFacets: min(10, max(0, totalGrams / max(1, Constants.Mass.measuredPebbleGrams))),
            diameter: JarLifetimeCoreBackdrop.coreDiameter(jarWidth: jarWidth, level: 1),
            effects: effects
        )
    }

    /// Long-term milestone traces, engraved on the jar's copper collar.
    private var milestoneTraceCount: Int {
        JarAccumulationPresencePresentation.state(
            totalGrams: totalGrams,
            effortSnapshot: JarAccumulationPresencePresentation.effortSnapshot(totalGrams: totalGrams)
        ).visibleMajorMilestoneTraceCount
    }

    /// Debug-only rendering counters for gem performance reviews in the
    /// Simulator (`POMOGEM_UI_TEST_SPRITE_STATS=1` with the UI-test launch).
    private static var spriteDebugOptions: SpriteView.DebugOptions {
#if DEBUG
        if LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
           ProcessInfo.processInfo.environment["POMOGEM_UI_TEST_SPRITE_STATS"] == "1" {
            return [.showsFPS, .showsNodeCount, .showsDrawCount]
        }
#endif
        return []
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
            hasStudyGems: scene.hasStudyGems
        )
        switch samplingMode {
        case .stopped:
            scene.cancelInteractionPresentation()
            // `stop` also restores the scene's default downward gravity. This
            // matters when interaction, app lifecycle, or an empty bottle no
            // longer needs the sensor while a prior tilt is still applied.
            motionObserver.stop()
        case .tiltAndShake:
            // Full rate while the jar is awake, the idle rate while it rests
            // (the observer follows `scene.fullRateMotionDemand`).
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

/// Where the scene's light may show (round 12): the whole bottle, and past
/// it a band that fades to nothing at the SKView's edge (smoothstep; the
/// 16 pt margins beside the bottle, the few points above and below it). A
/// halo or a bloom that runs past the bottle then fades out instead of
/// being cut by the view's rectangle. Below the bottle the band starts at
/// the glass base itself, so the base is never dimmed. Baked once per stage
/// size (1 px per point: the mask is smooth), used as the SpriteView's
/// mask.
enum JarLightBounds {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 4
        return cache
    }()

    /// Light stays whole this far outside the bottle's sides and top.
    static let clearance: CGFloat = 3

    /// The mask's coverage (0…1) at `x` along a stage `length` long that
    /// keeps `lower...upper` whole and fades to 0 at both ends (columns
    /// and rows use the same shape).
    static func coverage(at x: CGFloat, length: CGFloat, keepFrom lower: CGFloat, to upper: CGFloat) -> CGFloat {
        func smooth(_ t: CGFloat) -> CGFloat {
            let u = min(max(t, 0), 1)
            return u * u * (3 - 2 * u)
        }
        if x < lower {
            let band = max(lower - 0.5, 0.001)
            return smooth((x - 0.5) / band)
        }
        if x > upper {
            let band = max(length - 0.5 - upper, 0.001)
            return smooth((length - 0.5 - x) / band)
        }
        return 1
    }

    static func image(stageSize: CGSize) -> UIImage {
        let width = max(1, Int(stageSize.width.rounded()))
        let height = max(1, Int(stageSize.height.rounded()))
        let key = NSString(string: "\(width)x\(height)")
        if let cached = cache.object(forKey: key) { return cached }
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        let outer = JarScene.outerJarRect(sceneSize: size)
        // y down: the bottle's top and base.
        let top = size.height - outer.maxY
        let base = size.height - outer.minY
        let columns = (0 ..< width).map { column in
            coverage(
                at: CGFloat(column) + 0.5,
                length: size.width,
                keepFrom: outer.minX - clearance,
                to: outer.maxX + clearance
            )
        }
        let rows = (0 ..< height).map { row in
            coverage(
                at: CGFloat(row) + 0.5,
                length: size.height,
                keepFrom: top - clearance,
                to: base
            )
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0 ..< height {
            for column in 0 ..< width {
                let value = UInt8((columns[column] * rows[row] * 255).rounded())
                let index = (row * width + column) * 4
                // Premultiplied white.
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
                pixels[index + 3] = value
            }
        }
        let image: UIImage
        if let provider = CGDataProvider(data: Data(pixels) as CFData),
           let cgImage = CGImage(
               width: width,
               height: height,
               bitsPerComponent: 8,
               bitsPerPixel: 32,
               bytesPerRow: width * 4,
               space: CGColorSpaceCreateDeviceRGB(),
               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
               provider: provider,
               decode: nil,
               shouldInterpolate: true,
               intent: .defaultIntent
           ) {
            image = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        } else {
            image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }
        cache.setObject(image, forKey: key)
        return image
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
            // Mirrors JarScene.outerJarRect: the bottle is vertically centred
            // and at most `Constants.Jar.height` tall.
            let jarHeight = min(Constants.Jar.height, max(height, 1))
            let jarBottom = (height + jarHeight) / 2
            let jarWidth = max(width - Constants.Jar.horizontalMargin * 2, 1)

            ZStack(alignment: .topLeading) {
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
                .position(x: width / 2, y: height * 0.43)

                // The jar's own light, baked once per stage size (no blur,
                // no animation): floor pools, the rim bloom around the
                // glass, and the lit interior behind the core and the gems.
                // The floor light runs on past the stage's bottom edge.
                Image(uiImage: JarStageArtwork.image(
                    stageSize: proxy.size,
                    reduceTransparency: reduceTransparency
                ))
                .resizable()
                .frame(width: width, height: height + JarStageArtwork.bottomOverflow)
                .frame(width: width, height: height, alignment: .top)

                // Rim of light where the glass base meets the floor.
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                .clear,
                                PomoGemTheme.auroraWarm.opacity(0.70),
                                Color.white.opacity(0.80),
                                PomoGemTheme.auroraBlue.opacity(0.66),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: jarWidth * 0.90, height: 1.6)
                    .position(x: width / 2, y: jarBottom + 1)

                if !reduceTransparency {
                    JarFloorSparkles()
                        .frame(width: jarWidth * 1.1, height: 26)
                        .position(x: width / 2, y: jarBottom + 9)
                }
            }
            .frame(width: width, height: height)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// The static light of the jar stage (Docs/GemExperienceDesign.md §7.8),
/// baked with Core Graphics once per stage size and cached. It lies behind
/// the time core and the SpriteKit bottle:
///
/// - the floor: a soft contact shadow and two light pools, warm #FF8A5B on
///   the left and cool #5BA8FF on the right (α0.42/0.38, 0.62 of the jar
///   width each), as if the jar stood on glass;
/// - the rim bloom: warm light leaving the left wall, cool light the right;
/// - the interior: a violet body of light, brighter toward the floor where
///   the gems glow, warm/cool side light, a soft glow behind the core, and
///   ten still bokeh dots in the empty band (never over the core column).
///
/// `JarSnapshotter` draws the same image behind a share snapshot, so the
/// exported jar carries the same light as Home.
enum JarStageArtwork {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 6
        return cache
    }()

    /// Soft light only, so a modest scale is enough and keeps the bitmap
    /// small (about 1.7 MB for a 402 × 470 pt stage).
    static let renderScale: CGFloat = 1.5

    /// The floor light continues this far below the stage (the image is
    /// taller than the stage by this much), so it never ends in a hard edge.
    static let bottomOverflow: CGFloat = 60

    static func image(stageSize: CGSize, reduceTransparency: Bool) -> UIImage {
        let stage = CGSize(width: max(1, stageSize.width.rounded()), height: max(1, stageSize.height.rounded()))
        let size = CGSize(width: stage.width, height: stage.height + bottomOverflow)
        let key = NSString(string: "stage4|\(Int(stage.width))x\(Int(stage.height))|\(reduceTransparency ? 1 : 0)")
        if let cached = cache.object(forKey: key) { return cached }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = renderScale
        format.opaque = false
        format.preferredRange = .standard
        let strength: CGFloat = reduceTransparency ? 0.5 : 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            draw(in: renderer.cgContext, stageSize: stage, strength: strength)
        }
        cache.setObject(image, forKey: key)
        return image
    }

    /// The jar rectangle in stage coordinates (y down).
    static func jarRect(stageSize: CGSize) -> CGRect {
        let outer = JarScene.outerJarRect(sceneSize: stageSize)
        return CGRect(x: outer.minX, y: stageSize.height - outer.maxY, width: outer.width, height: outer.height)
    }

    /// The bottle outline in stage coordinates (y down).
    static func jarOutline(stageSize: CGSize) -> CGPath {
        let rect = jarRect(stageSize: stageSize)
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.minY * 2 + rect.height)
        let path = JarScene.jarPath(in: rect, neckInset: JarScene.neckInset(jarWidth: rect.width))
        return path.copy(using: &flip) ?? CGPath(rect: rect, transform: nil)
    }

    /// Draws the stage light into `context` (y down, stage points).
    static func draw(in context: CGContext, stageSize: CGSize, strength: CGFloat) {
        let jar = jarRect(stageSize: stageSize)
        let outline = jarOutline(stageSize: stageSize)
        let space = CGColorSpaceCreateDeviceRGB()
        func color(_ hex: String, _ alpha: CGFloat) -> CGColor {
            GemColor(hex: hex).withAlpha(alpha * strength).cgColor
        }
        func ellipse(center: CGPoint, radii: CGSize, colors: [CGColor], locations: [CGFloat]) {
            guard let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) else { return }
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.scaleBy(x: 1, y: radii.height / max(radii.width, 1))
            context.drawRadialGradient(
                gradient,
                startCenter: .zero, startRadius: 0,
                endCenter: .zero, endRadius: radii.width,
                options: []
            )
            context.restoreGState()
        }

        // Floor: contact shadow, then the warm and cool pools.
        ellipse(
            center: CGPoint(x: jar.midX, y: jar.maxY + 2),
            radii: CGSize(width: jar.width * 0.47, height: 17),
            colors: [UIColor.black.withAlphaComponent(0.30).cgColor, UIColor.black.withAlphaComponent(0).cgColor],
            locations: [0, 1]
        )
        for (hex, alpha, dx) in [("#FF8A5B", CGFloat(0.62), CGFloat(-0.22)), ("#5BA8FF", CGFloat(0.56), CGFloat(0.22))] {
            ellipse(
                center: CGPoint(x: jar.midX + jar.width * dx, y: jar.maxY + 10),
                radii: CGSize(width: jar.width * 0.30, height: 46),
                colors: [color(hex, alpha), color(hex, alpha * 0.42), color(hex, 0)],
                locations: [0, 0.45, 1]
            )
        }
        // The jar's light mirrored on the glass floor.
        ellipse(
            center: CGPoint(x: jar.midX, y: jar.maxY + 4),
            radii: CGSize(width: jar.width * 0.40, height: 20),
            colors: [color("#FFD9C2", 0.30), color("#C9A8FF", 0.12), color("#8068F6", 0)],
            locations: [0, 0.5, 1]
        )

        // Rim bloom: the silhouette's glow, a Gaussian (shadow blur, no
        // banding) warm on the left and cool on the right (masked by a
        // horizontal ramp).
        let pointsToPixels = context.userSpaceToDeviceSpaceTransform.a
        for (hex, alpha, fromLeft) in [(Constants.Color.auroraWarm, CGFloat(0.55), true), ("#6FB6FF", CGFloat(0.48), false)] {
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.saveGState()
            // Shadow blur is in device pixels: 12 pt at any bake scale.
            context.setShadow(offset: .zero, blur: 12 * max(1, abs(pointsToPixels)), color: color(hex, alpha))
            context.setStrokeColor(color(hex, alpha * 0.55))
            context.setLineWidth(3)
            context.setLineJoin(.round)
            context.addPath(outline)
            context.strokePath()
            context.restoreGState()
            context.setBlendMode(.destinationIn)
            let mask = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0.4).cgColor, UIColor.white.withAlphaComponent(0).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: mask, locations: [0, 0.34, 0.6]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: fromLeft ? jar.minX - 30 : jar.maxX + 30, y: 0),
                    end: CGPoint(x: fromLeft ? jar.maxX + 30 : jar.minX - 30, y: 0),
                    options: [.drawsBeforeStartLocation]
                )
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }

        // Interior light.
        context.saveGState()
        context.addPath(outline)
        context.clip()
        if let body = CGGradient(
            colorsSpace: space,
            colors: [
                color("#3E3A80", 0.50),
                color("#443A88", 0.46),
                color("#563A8A", 0.50),
                color("#8A5484", 0.60)
            ] as CFArray,
            locations: [0, 0.45, 0.75, 1]
        ) {
            context.drawLinearGradient(
                body,
                start: CGPoint(x: 0, y: jar.minY),
                end: CGPoint(x: 0, y: jar.maxY),
                options: []
            )
        }
        // The pile's own glow pooled above the floor.
        ellipse(
            center: CGPoint(x: jar.midX, y: jar.maxY - 14),
            radii: CGSize(width: jar.width * 0.56, height: 118),
            colors: [color("#FFA27E", 0.52), color("#C46AA8", 0.26), color("#8068F6", 0)],
            locations: [0, 0.5, 1]
        )
        // Side light through the thick walls: warm left, cool right.
        for (hex, fromLeft) in [(Constants.Color.auroraWarm, true), ("#6FB6FF", false)] {
            let side = [color(hex, 0.26), color(hex, 0.08), color(hex, 0)] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: side, locations: [0, 0.35, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: fromLeft ? jar.minX : jar.maxX, y: 0),
                    end: CGPoint(x: fromLeft ? jar.minX + jar.width * 0.28 : jar.maxX - jar.width * 0.28, y: 0),
                    options: []
                )
            }
        }
        // A soft violet glow where the time core sits.
        ellipse(
            center: CGPoint(x: jar.midX, y: jar.minY + jar.height * 0.42),
            radii: CGSize(width: jar.width * 0.40, height: jar.width * 0.40),
            colors: [color("#8C78FF", 0.26), color("#8068F6", 0.09), color("#8068F6", 0)],
            locations: [0, 0.5, 1]
        )
        // Still bokeh in the empty band beside the core column.
        let bokeh: [(x: CGFloat, y: CGFloat, r: CGFloat, hex: String, a: CGFloat)] = [
            (0.12, 0.30, 3.2, "#FFC27A", 0.42), (0.20, 0.52, 2.2, "#FF9E6B", 0.34),
            (0.10, 0.66, 3.8, "#FFE3B0", 0.30), (0.24, 0.40, 1.6, "#8ACBFF", 0.40),
            (0.17, 0.74, 2.6, "#FFC27A", 0.28), (0.86, 0.28, 2.6, "#8ACBFF", 0.38),
            (0.80, 0.46, 3.6, "#FFE3B0", 0.30), (0.90, 0.60, 2.0, "#FF9E6B", 0.40),
            (0.76, 0.70, 3.0, "#FFC27A", 0.26), (0.83, 0.36, 1.5, "#FFFFFF", 0.46)
        ]
        for dot in bokeh {
            let center = CGPoint(x: jar.minX + jar.width * dot.x, y: jar.minY + jar.height * dot.y)
            ellipse(
                center: center,
                radii: CGSize(width: dot.r * 2.2, height: dot.r * 2.2),
                colors: [color(dot.hex, dot.a), color(dot.hex, dot.a * 0.55), color(dot.hex, 0)],
                locations: [0, 0.42, 1]
            )
        }
        context.restoreGState()
    }
}

/// The centrepiece Home draws behind the bottle, as data a share snapshot
/// can redraw: the time core (share fan and level) or, before 2.5 kg, the
/// colourless vessel with its lit facets.
struct JarShareCore: Equatable {
    /// The lifetime theme fan as Home has it (unquantised; every consumer
    /// quantises it the same way, and the marks need the themes).
    let shares: [GemColorShare]
    let level: Int
    /// Lit facets of the colourless vessel; nil for the born core.
    let vesselLitFacets: Int?
    /// Diameter of the core frame on Home (points).
    let diameter: CGFloat
    /// Differentiate Without Color: the stone carries its theme marks.
    var themeMarks = false
    /// 演出の強さ in effect on Home (D17): 控えめ draws lighter lights.
    var effects: JarEffectsIntensity = .standard
}

/// Core Graphics twin of `JarLifetimeCoreBackdrop` / `JarLifetimeCoreVessel`
/// for share snapshots: bloom, the two halo lobes, girdle bloom, a quiet
/// orbit ring and the same baked stone image.
enum JarShareCoreArtwork {
    /// Share snapshots place the centrepiece in the upper middle of the
    /// bottle (there is no HUD on a card): this share of the jar height
    /// from the top.
    static let centerFraction: CGFloat = 0.42

    static func stoneImage(for core: JarShareCore, scale: CGFloat) -> UIImage {
        if let lit = core.vesselLitFacets {
            return GemArtwork.vesselImage(litFacets: lit, scale: scale)
        }
        return GemArtwork.coreImage(shares: core.shares, level: core.level, scale: scale, themeMarks: core.themeMarks)
    }

    /// Frame of the stone image around `center` (points).
    static func stoneRect(for core: JarShareCore, center: CGPoint) -> CGRect {
        let side = core.vesselLitFacets == nil ? core.diameter : core.diameter * 0.92
        return CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }

    /// Draws the lights and the stone around `center` (y-down context).
    static func draw(_ core: JarShareCore, center: CGPoint, in context: CGContext, scale: CGFloat) {
        let space = CGColorSpaceCreateDeviceRGB()
        let d = core.diameter
        func radial(_ colors: [UIColor], _ locations: [CGFloat], from r0: CGFloat, to r1: CGFloat, clip: CGRect? = nil, offset: CGFloat = 0) {
            guard let gradient = CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: locations) else { return }
            context.saveGState()
            let c = CGPoint(x: center.x + offset, y: center.y)
            if let clip { context.addEllipse(in: clip.offsetBy(dx: c.x, dy: c.y)); context.clip() }
            context.drawRadialGradient(gradient, startCenter: c, startRadius: r0, endCenter: c, endRadius: r1, options: [.drawsBeforeStartLocation])
            context.restoreGState()
        }
        // 控えめ (D17): the bloom, the lobes and the girdle bloom at the
        // halo scale; the colourless vessel's light at the inner-glow scale.
        let halo = core.effects.haloScale
        let inner = core.effects.innerGlowScale
        if core.vesselLitFacets != nil {
            let white = UIColor.white
            radial([white.withAlphaComponent(0.30 * inner), white.withAlphaComponent(0.10 * inner), .clear], [0, 0.5, 1], from: d * 0.30, to: d * 0.65)
        } else {
            let haloColor = GemArtwork.coreHaloColor(shares: core.shares)
            let lobes = GemArtwork.coreHaloLobeColors(shares: core.shares)
            let rim = GemArtwork.coreRimGlowColor(shares: core.shares)
            radial(
                [haloColor.withAlphaComponent(0.24 * halo), GemColor(hex: Constants.Color.auroraViolet).withAlpha(0.05 * halo), .clear],
                [0, 0.5, 1],
                from: 3,
                to: d * 1.25
            )
            // Quiet orbit ring (copper, dashed); the markers stay on Home.
            context.saveGState()
            context.setStrokeColor(GemColor(hex: "#D9967A").withAlpha(0.45).cgColor)
            context.setLineWidth(1)
            context.setLineDash(phase: 0, lengths: [3, 5])
            let orbit = d * 1.075
            context.strokeEllipse(in: CGRect(x: center.x - orbit, y: center.y - orbit, width: orbit * 2, height: orbit * 2))
            context.restoreGState()
            for (color, side) in [(lobes.left, CGFloat(-1)), (lobes.right, CGFloat(1))] {
                radial(
                    [color.withAlphaComponent(0.45 * halo), color.withAlphaComponent(0.20 * halo), .clear],
                    [0, 0.5, 1],
                    from: d * 0.30,
                    to: d * 0.70,
                    clip: CGRect(x: -d * 0.575, y: -d * 0.70, width: d * 1.15, height: d * 1.40),
                    offset: side * d * 0.16
                )
            }
            radial([rim.withAlphaComponent(0.95 * halo), rim.withAlphaComponent(0.34 * halo), .clear], [0, 0.5, 1], from: d * 0.44, to: d * 0.62)
        }
        guard let stone = stoneImage(for: core, scale: scale).cgImage else { return }
        let rect = stoneRect(for: core, center: center)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(stone, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

/// What a share GIF animates over the flattened jar snapshot: the stone
/// (for a slow 1.00 ↔ 1.04 breath and its glow) and a few glint anchors on
/// the highest gems, all normalised to the snapshot (0…1, y down).
struct ShareJarMotion {
    /// The stone to breathe; nil when gems overlap it (it stays behind).
    let stone: UIImage?
    let stoneRect: CGRect
    let glowColor: UIColor
    let glints: [CGPoint]
    /// 演出の強さ the jar showed (D17): 控えめ holds the breath, dims the
    /// glow and lights no glints.
    var effects: JarEffectsIntensity = .standard
}

/// Four static star glints on the floor, drawn once (no animation). Each is
/// asymmetric — the horizontal arm 1.6× the vertical — so they read as light
/// caught on glass rather than clip-art crosses.
private struct JarFloorSparkles: View {
    var body: some View {
        Canvas { context, size in
            let points: [(x: CGFloat, y: CGFloat, length: CGFloat, alpha: Double)] = [
                (0.10, 0.42, 5.5, 0.55),
                (0.31, 0.80, 3.8, 0.38),
                (0.70, 0.58, 5.0, 0.50),
                (0.92, 0.30, 3.6, 0.35)
            ]
            for point in points {
                let center = CGPoint(x: size.width * point.x, y: size.height * point.y)
                for vertical in [false, true] {
                    let arm = vertical ? point.length : point.length * 1.6
                    let rect = vertical
                        ? CGRect(x: center.x - 0.6, y: center.y - arm, width: 1.2, height: arm * 2)
                        : CGRect(x: center.x - arm, y: center.y - 0.6, width: arm * 2, height: 1.2)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .radialGradient(
                            Gradient(colors: [.white.opacity(point.alpha), .white.opacity(0)]),
                            center: center,
                            startRadius: 0,
                            endRadius: arm
                        )
                    )
                }
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 1.8, y: center.y - 1.8, width: 3.6, height: 3.6)),
                    with: .radialGradient(
                        Gradient(colors: [.white.opacity(point.alpha), .white.opacity(0)]),
                        center: center,
                        startRadius: 0,
                        endRadius: 1.8
                    )
                )
            }
        }
    }
}
