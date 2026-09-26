import CoreGraphics
import SpriteKit

/// Decides whether the live jar can stand in for a share card's bottle
/// (jar-04, screentime-11).
///
/// A share capture hides pebbles the card must not show (black Screen Time
/// stones always, self-reported focus unless it is included) in the live,
/// already-settled physics pile. Nothing re-settles, so a gem that was
/// resting on a hidden pebble stays where it was, floating over a
/// pebble-sized hole, in the most public image the app makes. When hiding
/// would do that, the composer uses the card's own drawn bottle
/// (`ShareJarGraphic`) instead, which is built from exactly the shared
/// records. Hidden pebbles that hold nothing up, such as black stones packed
/// on top of the pile after a relaunch, still allow the real jar.
///
/// F3: a pile resting off the jar's floor is a separate reason for the
/// drawn bottle (`pileRestsOnTheFloor(in:)`). The composer asks
/// `livePileNeedsDrawnBottle(in:options:)`, which asks both.
enum ShareJarSnapshotPolicy {
    struct Body: Equatable {
        let center: CGPoint
        let radius: CGFloat
    }

    /// A visible body counts as held up by a hidden one when the two touch
    /// and the visible body sits above it along `up`: its direction from the
    /// hidden center is more than about 12° above the horizontal. Side-by-side
    /// contact leaves a hole but nothing floating.
    static let minimumSupportElevation: CGFloat = 0.2
    /// Settled circles overlap or sit a hair apart; this keeps both as contact.
    static let contactTolerance: CGFloat = 1

    static func hidingLeavesUnsupportedBody(
        hidden: [Body],
        visible: [Body],
        up: CGVector = CGVector(dx: 0, dy: 1)
    ) -> Bool {
        guard !hidden.isEmpty, !visible.isEmpty else { return false }
        let length = (up.dx * up.dx + up.dy * up.dy).squareRoot()
        let unitUp = length > 0.0001
            ? CGVector(dx: up.dx / length, dy: up.dy / length)
            : CGVector(dx: 0, dy: 1)
        for support in hidden {
            for body in visible {
                let dx = body.center.x - support.center.x
                let dy = body.center.y - support.center.y
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance > 0.0001 else { return true }
                guard distance <= support.radius + body.radius + contactTolerance else {
                    continue
                }
                let elevation = (dx * unitUp.dx + dy * unitUp.dy) / distance
                if elevation > minimumSupportElevation { return true }
            }
        }
        return false
    }

    /// Whether the live jar's bodies rest on its floor (F3,
    /// `JarScene.pileRestsOnTheFloor`: within 30° of the jar's own down).
    /// Any other scene counts as resting on its floor.
    ///
    /// A pile resting against a wall or the invisible cap (the phone held
    /// sideways or upside down when it settled) would hang on the side or
    /// at the mouth of the card's upright bottle, so the card draws its own
    /// bottle when this is false, whatever a share hides. It
    /// reads the pose the pile settled in, not the live gravity a sheet
    /// resets (`JarScene.pileGravityVector`).
    @MainActor
    static func pileRestsOnTheFloor(in scene: SKScene) -> Bool {
        (scene as? JarScene)?.pileRestsOnTheFloor ?? true
    }

    /// Splits the scene's pebbles with the snapshotter's own hiding rule and
    /// checks them against the gravity the bodies rest under: for the jar,
    /// the gravity its resting pile settled under (F3: the motion observer
    /// resets the live gravity while a sheet covers Home, without moving
    /// the frozen pile), otherwise the scene's current gravity. It answers
    /// only for the hidden bodies: whether the pile rests on the floor at
    /// all is `pileRestsOnTheFloor(in:)`'s question.
    @MainActor
    static func hidingLeavesUnsupportedBody(
        in scene: SKScene,
        options: JarSnapshotOptions
    ) -> Bool {
        var hidden: [Body] = []
        var visible: [Body] = []
        scene.enumerateChildNodes(withName: "//*") { node, _ in
            guard let pebble = node as? PebbleNode,
                  !pebble.isHidden,
                  let parent = pebble.parent else { return }
            let body = Body(
                center: scene.convert(pebble.position, from: parent),
                radius: pebble.radius
            )
            if options.hides(pebble.descriptor) {
                hidden.append(body)
            } else {
                visible.append(body)
            }
        }
        let gravity = (scene as? JarScene)?.pileGravityVector ?? scene.physicsWorld.gravity
        return hidingLeavesUnsupportedBody(
            hidden: hidden,
            visible: visible,
            up: CGVector(dx: -gravity.dx, dy: -gravity.dy)
        )
    }

    /// The composer's decision: the card draws its own bottle when the pile
    /// rests off the floor (F3) or hiding leaves a visible gem unsupported,
    /// and shows the live jar otherwise.
    @MainActor
    static func livePileNeedsDrawnBottle(
        in scene: SKScene,
        options: JarSnapshotOptions
    ) -> Bool {
        !pileRestsOnTheFloor(in: scene)
            || hidingLeavesUnsupportedBody(in: scene, options: options)
    }
}
