import CoreGraphics

/// F3 (Docs/JarOrientationGravity.md, owner ruling 2026-09-27): held upside
/// down, the jar's gems rest against the cap, right behind Home's metric HUD.
/// The HUD stays on top and legible: while a settled gem lies behind the
/// HUD's measured frame, the soft ink scrim behind its text is drawn stronger
/// (the same ellipse, a higher opacity). The HUD never moves or shrinks, and
/// the gems never fade. The 「N巡」 pill under the neck is part of the HUD
/// (review F1, 2026-09-29): while a settled gem lies behind it, Home draws it
/// in front of the scene with the same strengthened ink, where it always is.
///
/// Review F2 (2026-09-29): "behind" is judged gem by gem (each resting
/// body's circle against the frame), not by the pile's bounding box, which
/// for a corner or L-shaped pile covers empty glass.
enum JarHUDScrimPolicy {
    enum Strength: Equatable {
        /// The scrim the HUD always had (the core, orbit markers and glowing
        /// gems behind the glass).
        case standard
        /// A settled pile lies behind the HUD.
        case strengthened
    }

    /// One resting body: its circle (in the scene, y up, or in a stage's
    /// coordinate space, y down).
    struct Body: Equatable, Sendable {
        let center: CGPoint
        let radius: CGFloat
    }

    /// The ink of the scrim's radial gradient: black at `center`, easing
    /// to black at `middle`, then clear.
    struct Ink: Equatable {
        let center: Double
        let middle: Double
    }

    static let standardInk = Ink(center: 0.34, middle: 0.14)
    static let strengthenedInk = Ink(center: 0.64, middle: 0.38)

    /// `strengthened` while one of the settled pile's bodies meets the
    /// HUD's frame (all in the same coordinate space; touching does not
    /// count). Without a settled pile, before the HUD is measured, or with
    /// a degenerate frame, the HUD keeps its standard scrim.
    static func strength(pileBodies: [Body], hudFrame: CGRect?) -> Strength {
        guard let hudFrame else { return .standard }
        return meets(pileBodies, frame: hudFrame) ? .strengthened : .standard
    }

    /// Whether any of `bodies` overlaps `frame` (a circle meeting the
    /// rectangle's interior; touching does not count). False for a
    /// degenerate frame; degenerate bodies are skipped.
    static func meets(_ bodies: [Body], frame: CGRect) -> Bool {
        guard isUsable(frame) else { return false }
        return bodies.contains { body in
            guard body.center.x.isFinite, body.center.y.isFinite,
                  body.radius.isFinite, body.radius > 0
            else { return false }
            // The frame's point nearest the circle's centre.
            let nearestX = min(max(body.center.x, frame.minX), frame.maxX)
            let nearestY = min(max(body.center.y, frame.minY), frame.maxY)
            return hypot(body.center.x - nearestX, body.center.y - nearestY) < body.radius
        }
    }

    /// Review F1: whether Home draws the 「N巡」 pill in front of the scene
    /// (over `strengthenedInk`): while one of the settled pile's bodies
    /// meets the pill's measured frame (both in the stage's coordinate
    /// space). Before the pill is measured it stays where it always was,
    /// behind the scene.
    static func liftsCyclePill(pileBodies: [Body], pillFrame: CGRect?) -> Bool {
        guard let pillFrame else { return false }
        return meets(pileBodies, frame: pillFrame)
    }

    static func ink(for strength: Strength) -> Ink {
        switch strength {
        case .standard: return standardInk
        case .strengthened: return strengthenedInk
        }
    }

    /// Scene bodies (SpriteKit points, y up from the stage's bottom) in
    /// the coordinate space the stage's frame `stageFrame` is measured in
    /// (y down). The jar scene is exactly the size of its stage
    /// (`JarSpriteView` sets `scene.size` to it). Empty for a missing or
    /// degenerate stage.
    static func stageBodies(ofScene bodies: [Body], stageFrame: CGRect?) -> [Body] {
        guard let stageFrame, isUsable(stageFrame) else { return [] }
        return bodies.map { body in
            Body(
                center: CGPoint(
                    x: stageFrame.minX + body.center.x,
                    y: stageFrame.minY + stageFrame.height - body.center.y
                ),
                radius: body.radius
            )
        }
    }

    /// The scene rectangle `sceneRect` (SpriteKit points, y up from the
    /// stage's bottom) in the coordinate space the stage's frame
    /// `stageFrame` is measured in (y down). Nil for a missing or
    /// degenerate input.
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
