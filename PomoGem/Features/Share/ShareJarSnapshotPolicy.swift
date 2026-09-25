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

    /// Splits the scene's pebbles with the snapshotter's own hiding rule and
    /// checks them against the scene's current gravity.
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
        let gravity = scene.physicsWorld.gravity
        return hidingLeavesUnsupportedBody(
            hidden: hidden,
            visible: visible,
            up: CGVector(dx: -gravity.dx, dy: -gravity.dy)
        )
    }
}
