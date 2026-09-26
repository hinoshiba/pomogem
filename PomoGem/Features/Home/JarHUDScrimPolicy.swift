import CoreGraphics

/// F3 (Docs/JarOrientationGravity.md, owner ruling 2026-09-27): held upside
/// down, the jar's gems rest against the cap, right behind Home's metric HUD.
/// The HUD stays on top and legible: while the settled pile's bounds meet the
/// HUD's measured frame, the soft ink scrim behind its text is drawn stronger
/// (the same ellipse, a higher opacity). The HUD never moves or shrinks, and
/// the gems never fade.
enum JarHUDScrimPolicy {
    enum Strength: Equatable {
        /// The scrim the HUD always had (the core, orbit markers and glowing
        /// gems behind the glass).
        case standard
        /// A settled pile lies behind the HUD.
        case strengthened
    }

    /// The ink of the scrim's radial gradient: black at `center`, easing
    /// to black at `middle`, then clear.
    struct Ink: Equatable {
        let center: Double
        let middle: Double
    }

    static let standardInk = Ink(center: 0.34, middle: 0.14)
    static let strengthenedInk = Ink(center: 0.64, middle: 0.38)

    /// `strengthened` while the settled pile's bounds and the HUD's frame
    /// overlap (both in the same coordinate space; touching edges do not
    /// count). Without a settled pile, before the HUD is measured, or with
    /// a degenerate rectangle, the HUD keeps its standard scrim.
    static func strength(pileBounds: CGRect?, hudFrame: CGRect?) -> Strength {
        guard let pileBounds, let hudFrame,
              isUsable(pileBounds), isUsable(hudFrame)
        else { return .standard }
        let overlap = pileBounds.intersection(hudFrame)
        return overlap.isNull || overlap.isEmpty ? .standard : .strengthened
    }

    static func ink(for strength: Strength) -> Ink {
        switch strength {
        case .standard: return standardInk
        case .strengthened: return strengthenedInk
        }
    }

    /// The scene rectangle `sceneRect` (SpriteKit points, y up from the
    /// stage's bottom) in the coordinate space the stage's frame
    /// `stageFrame` is measured in (y down). The jar scene is exactly the
    /// size of its stage (`JarSpriteView` sets `scene.size` to it). Nil
    /// for a missing or degenerate input.
    static func stageRect(ofScene sceneRect: CGRect?, stageFrame: CGRect?) -> CGRect? {
        guard let sceneRect, let stageFrame,
              isUsable(sceneRect), isUsable(stageFrame)
        else { return nil }
        return CGRect(
            x: stageFrame.minX + sceneRect.minX,
            y: stageFrame.minY + stageFrame.height - sceneRect.maxY,
            width: sceneRect.width,
            height: sceneRect.height
        )
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite
            && rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
