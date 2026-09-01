import SpriteKit
import SwiftUI
import UIKit

/// Keeps the jar's spoken hierarchy aligned with the visible value hierarchy:
/// elapsed mass first, count-based storage second, and zero-mass achievements
/// as a separate record. This is pure so the ordering can be regression tested.
enum JarAccessibilityPresentation {
    static func value(
        totalGrams rawTotalGrams: Int,
        pebbleCount rawPebbleCount: Int,
        achievementCount rawAchievementCount: Int,
        aggregateCount rawAggregateCount: Int,
        representedPebbleCount rawRepresentedPebbleCount: Int,
        goldPebbleCount rawGoldPebbleCount: Int,
        prismPebbleCount rawPrismPebbleCount: Int,
        fusionProgressDescription: String?,
        projectionIsLowerBound: Bool
    ) -> String {
        let totalGrams = max(0, rawTotalGrams)
        let pebbleCount = max(0, rawPebbleCount)
        let achievementCount = max(0, rawAchievementCount)
        let aggregateCount = max(0, rawAggregateCount)
        let representedPebbleCount = max(0, rawRepresentedPebbleCount)
        let goldPebbleCount = max(0, rawGoldPebbleCount)
        let prismPebbleCount = max(0, rawPrismPebbleCount)
        let aggregate = aggregateCount > 0
            ? "、まとまり粒\(aggregateCount)個、合計\(representedPebbleCount)粒分"
            : ""
        let fusion = fusionProgressDescription.map { "、\($0)" } ?? ""
        let rare = [
            goldPebbleCount > 0 ? "金\(goldPebbleCount)粒" : nil,
            prismPebbleCount > 0 ? "虹\(prismPebbleCount)粒" : nil
        ].compactMap { $0 }.joined(separator: "、")
        let rareSuffix = rare.isEmpty ? "" : "、\(rare)"
        let massDescription = projectionIsLowerBound
            ? "現在確認できた集中時間の質量：\(formattedMass(totalGrams))以上、同期中"
            : "記録した集中時間の質量：\(formattedMass(totalGrams))"
        return "\(massDescription)。瓶の整理：\(pebbleCount)粒\(aggregate)\(rareSuffix)\(fusion)。記念石\(achievementCount)個"
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
    let representedPebbleCount: Int
    let goldPebbleCount: Int
    let prismPebbleCount: Int
    let accentHex: String
    let lifetimeCoreColorHex: String
    let projectionIsLowerBound: Bool
    let fusionProgressDescription: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var motionObserver: JarMotionObserver
#if targetEnvironment(macCatalyst)
    @State private var catalystGestureOwnership = JarDragGestureOwnership()
#endif

    init(
        scene: JarScene,
        totalGrams: Int,
        pebbleCount: Int,
        achievementCount: Int = 0,
        aggregateCount: Int = 0,
        representedPebbleCount: Int? = nil,
        goldPebbleCount: Int = 0,
        prismPebbleCount: Int = 0,
        accentHex: String = Constants.Color.amberLamp,
        lifetimeCoreColorHex: String? = nil,
        projectionIsLowerBound: Bool = false,
        fusionProgressDescription: String? = nil
    ) {
        _scene = ObservedObject(wrappedValue: scene)
        self.totalGrams = totalGrams
        self.pebbleCount = pebbleCount
        self.achievementCount = achievementCount
        self.aggregateCount = aggregateCount
        self.representedPebbleCount = representedPebbleCount ?? pebbleCount
        self.goldPebbleCount = max(0, goldPebbleCount)
        self.prismPebbleCount = max(0, prismPebbleCount)
        self.accentHex = accentHex
        self.lifetimeCoreColorHex = lifetimeCoreColorHex ?? accentHex
        self.projectionIsLowerBound = projectionIsLowerBound
        self.fusionProgressDescription = fusionProgressDescription
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
                .gesture(
                    SpatialTapGesture(coordinateSpace: .local)
                        .onEnded { value in
                            _ = scene.bouncePebbles(at: CGPoint(
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
            reduceMotion: reduceMotion
        ))
        .onChange(of: reduceMotion) { _, enabled in
            updateMotionBehavior(reduceMotion: enabled)
        }
        .onDisappear {
            motionObserver.stop()
        }
    }

    private var accessibilityValue: String {
        JarAccessibilityPresentation.value(
            totalGrams: totalGrams,
            pebbleCount: pebbleCount,
            achievementCount: achievementCount,
            aggregateCount: aggregateCount,
            representedPebbleCount: representedPebbleCount,
            goldPebbleCount: goldPebbleCount,
            prismPebbleCount: prismPebbleCount,
            fusionProgressDescription: fusionProgressDescription,
            projectionIsLowerBound: projectionIsLowerBound
        )
    }

    private var accessibilityHint: String {
        guard hasPhysicalContent else {
            return "まだ粒はありません。集中を完走するか成果を積むと、瓶に粒が入ります"
        }
#if targetEnvironment(macCatalyst)
        return "瓶をクリックすると粒が跳ねます。左右にドラッグするか、VoiceOverのカスタムアクションでも粒を動かせます"
#else
        if reduceMotion {
            return "ダブルタップした位置が短く光ります。粒は移動しません"
        }
        return "瓶をタップすると近くの粒が跳ねます。iPhoneを傾けるか、カスタムアクションでも粒を動かせます"
#endif
    }

    /// One physical source of truth covers loose pebbles, aggregates,
    /// achievement stones, and migrated strata alike.
    var hasPhysicalContent: Bool {
        scene.physicalPebbleCount > 0
    }

    @MainActor
    private func updateMotionBehavior(reduceMotion: Bool) {
        scene.reduceMotion = reduceMotion
#if targetEnvironment(macCatalyst)
        // Catalyst has no device tilt. Drag and accessibility actions are the
        // explicit input paths, while stop restores stable downward gravity.
        motionObserver.stop()
#else
        if reduceMotion {
            // `stop` also restores the scene's default downward gravity. This
            // matters when Reduce Motion is enabled while an already-mounted
            // bottle is responding to device tilt.
            motionObserver.stop()
        } else {
            motionObserver.start(scene: scene)
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
                    smoothing: false
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
                    _ = scene.bouncePebbles(at: CGPoint(
                        x: value.location.x,
                        y: height - value.location.y
                    ))
                }
            }
    }
#endif
}

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
    let reduceMotion: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isInteractive {
            content
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    performBounce()
                }
                .accessibilityAction(named: "瓶の粒を跳ねさせる") {
                    performBounce()
                }
                .modifier(JarDirectionalAccessibilityModifier(
                    scene: scene,
                    enabled: !reduceMotion
                ))
        } else {
            content
        }
    }

    private func performBounce() {
        guard scene.bouncePebbles() else { return }
        UIAccessibility.post(
            notification: .announcement,
            argument: reduceMotion ? "瓶が光りました" : "瓶の粒が跳ねました"
        )
    }
}

private struct JarDirectionalAccessibilityModifier: ViewModifier {
    let scene: JarScene
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityAction(named: "瓶の粒を左へ動かす") {
                    scene.nudge(horizontal: -1)
                }
                .accessibilityAction(named: "瓶の粒を右へ動かす") {
                    scene.nudge(horizontal: 1)
                }
        } else {
            content
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
                        TsumibenTheme.auroraWarm.opacity(reduceTransparency ? 0.035 : 0.085),
                        TsumibenTheme.auroraViolet.opacity(reduceTransparency ? 0.025 : 0.065),
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
                                TsumibenTheme.auroraBlue.opacity(reduceTransparency ? 0.08 : 0.18),
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
