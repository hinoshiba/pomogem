import SwiftUI

/// The soft ink scrim behind Home's metric HUD (Docs/JarOrientationGravity.md).
/// It keeps the value legible over the brighter core, orbit markers and
/// glowing gems behind the glass, and draws in a stronger ink while the jar's
/// settled pile lies behind the readout (`JarHUDScrimPolicy`; held upside
/// down, the pile rests against the cap). It observes the scene itself and
/// measures the readout it backs, so a pile moving while the jar is awake
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
            pileBounds: JarHUDScrimPolicy.stageRect(
                ofScene: scene.settledPileBounds,
                stageFrame: stageFrame
            ),
            hudFrame: hudFrame
        )
    }

    var body: some View {
        let ink = JarHUDScrimPolicy.ink(for: strength)
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [Color.black.opacity(ink.center), Color.black.opacity(ink.middle), .clear],
                    center: .center,
                    startRadius: 4,
                    endRadius: 120
                )
            )
            .frame(width: 250, height: 150)
            .blur(radius: 8)
            .animation(.easeInOut(duration: 0.35), value: ink)
            // The background is laid out at the readout's own frame: that
            // is the HUD frame the policy compares with the pile.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGRect.self) { geometry in
                geometry.frame(in: .named(coordinateSpace))
            } action: { frame in
                hudFrame = frame
            }
    }
}
