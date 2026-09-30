import SwiftUI

/// The soft ink scrim behind Home's metric HUD (Docs/JarOrientationGravity.md).
/// It keeps the value legible over the brighter core, orbit markers and
/// glowing gems behind the glass, and draws in a stronger ink while a gem of
/// the jar's settled pile lies behind the readout (`JarHUDScrimPolicy`; held
/// upside down, the pile rests against the cap). It observes the scene itself
/// and measures the readout it backs, so a pile moving while the jar is awake
/// redraws only this scrim, never Home.
struct JarHUDInkScrim: View {
    @ObservedObject var scene: JarScene
    /// The jar stage's frame in `coordinateSpace` (the scene is its size).
    let stageFrame: CGRect
    let coordinateSpace: String
    /// False where the HUD sits outside the jar (the Simulator-only D5
    /// preview): no pile can lie behind it.
    let followsPile: Bool
    @State private var hudFrame: CGRect?

    private var strength: JarHUDScrimPolicy.Strength {
        guard followsPile else { return .standard }
        return JarHUDScrimPolicy.strength(
            pileBodies: JarHUDScrimPolicy.stageBodies(
                ofScene: scene.settledPileBodies,
                stageFrame: stageFrame
            ),
            hudFrame: hudFrame
        )
    }

    var body: some View {
        // Laid out as the readout's background, the clear layer takes the
        // readout's own frame: that is the HUD frame the policy compares
        // with the gems (review F2: the 250 × 150 scrim drawn over it would
        // report its own, larger box). The scrim is drawn over it, centred,
        // without taking part in the layout.
        Color.clear
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named(coordinateSpace))
            } action: { frame in
                hudFrame = frame
            }
            .overlay {
                JarInkScrimShape(
                    ink: JarHUDScrimPolicy.ink(for: strength),
                    size: CGSize(width: 250, height: 150),
                    endRadius: 120
                )
            }
    }
}

/// The soft elliptical ink behind a HUD text: black at the centre fading
/// out, blurred, in `ink`'s opacities (changes animate over 0.35 s).
struct JarInkScrimShape: View {
    let ink: JarHUDScrimPolicy.Ink
    let size: CGSize
    let endRadius: CGFloat

    var body: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [Color.black.opacity(ink.center), Color.black.opacity(ink.middle), .clear],
                    center: .center,
                    startRadius: 4,
                    endRadius: endRadius
                )
            )
            .frame(width: size.width, height: size.height)
            .blur(radius: 8)
            .animation(.easeInOut(duration: 0.35), value: ink)
            .allowsHitTesting(false)
    }
}
