import SpriteKit
import UIKit

/// Matte, chipped rubble. It shares the jar's physical collision shape, but
/// has none of the study crystals' glow or reward marks.
///
/// The outline, six facets and the crack are the same native paths as
/// before, baked once per shape into one atlas sprite (`obstacle.body`)
/// instead of eight shape nodes (fifteen draws per stone). Only the count
/// stays a live label, because it turns to remain upright.
enum ScreenTimeObstacleAppearance {
    static let bodyName = "obstacle.body"
    static let countName = "obstacle.count"

    /// Installs the rubble on `node` (a pebble container that draws nothing
    /// itself) and returns the upright count label, if the stone has one.
    @MainActor
    @discardableResult
    static func apply(
        to node: SKShapeNode,
        descriptor: ScreenTimeObstacleDescriptor,
        radius: CGFloat,
        scale: CGFloat = PebbleNode.defaultArtworkScale
    ) -> SKLabelNode? {
        let points = outline(descriptor: descriptor, radius: radius)
        node.path = path(through: points)
        node.fillColor = .clear
        node.strokeColor = .clear
        node.lineWidth = 0
        node.glowWidth = 0
        node.addChild(makeBodySprite(descriptor: descriptor, radius: radius, scale: scale))

        guard descriptor.level > 0 || descriptor.isHistoryPile else { return nil }
        let label = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
        label.name = countName
        label.text = descriptor.isHistoryPile ? "…" : "×\(descriptor.representedUnits.formatted())"
        label.fontSize = descriptor.level > 3 ? 7 : 9
        label.fontColor = UIColor(white: 0.82, alpha: 1)
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.zPosition = 0.4
        if label.frame.width > radius * 1.6 {
            label.setScale(radius * 1.6 / label.frame.width)
        }
        node.addChild(label)
        return label
    }

    /// The baked rubble as one sprite (also used by the carry gesture's
    /// non-physical copies).
    @MainActor
    static func makeBodySprite(
        descriptor: ScreenTimeObstacleDescriptor,
        radius: CGFloat,
        scale: CGFloat
    ) -> SKSpriteNode {
        let sprite = SKSpriteNode(texture: nil, size: spriteSize(radius: radius))
        sprite.name = bodyName
        sprite.zPosition = 0
        let variations = self.variations(descriptor: descriptor)
        GemTextureAtlas.shared.show(
            textureName(variations: variations, radius: radius, scale: scale),
            on: sprite
        ) {
            image(variations: variations, radius: radius, scale: scale)
        }
        return sprite
    }

    /// The outline's twelve radial variations (0…10). Stones with equal
    /// variations and radius share one texture.
    static func variations(descriptor: ScreenTimeObstacleDescriptor) -> [Int] {
        let bytes = Array(descriptor.id.uuidString.utf8)
        return (0 ..< 12).map { Int(bytes[$0 % bytes.count] % 11) }
    }

    static func textureName(variations: [Int], radius: CGFloat, scale: CGFloat) -> String {
        let shape = variations.map(String.init).joined(separator: ".")
        return "gem.obstacle|\(shape)|r\(radius)|x\(GemArtwork.renderScale(scale))"
    }

    /// Stroke margin around the outline (points).
    static let margin: CGFloat = 1.5

    static func spriteSize(radius: CGFloat) -> CGSize {
        let side = (radius + margin) * 2
        return CGSize(width: side, height: side)
    }

    /// Core Graphics bake of the rubble in the order SpriteKit drew its
    /// shape nodes: outline fill and stroke, the six facets (fill, then
    /// stroke) and the crack on top. Thread-safe.
    static func image(variations: [Int], radius: CGFloat, scale: CGFloat) -> UIImage {
        let size = spriteSize(radius: radius)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = GemArtwork.renderScale(scale)
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            // Scene space (y up, origin at the stone's centre) → image space.
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: 1, y: -1)
            context.setLineJoin(.miter)
            context.setLineCap(.butt)

            let points = outline(variations: variations, radius: radius)
            let outlinePath = path(through: points)
            context.addPath(outlinePath)
            context.setFillColor(UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1).cgColor)
            context.fillPath()
            context.addPath(outlinePath)
            context.setStrokeColor(UIColor(red: 0.39, green: 0.38, blue: 0.42, alpha: 1).cgColor)
            context.setLineWidth(1.2)
            context.strokePath()

            for index in stride(from: 0, to: points.count, by: 2) {
                let facet = CGMutablePath()
                facet.move(to: CGPoint(x: -radius * 0.08, y: radius * 0.06))
                facet.addLine(to: points[index])
                facet.addLine(to: points[(index + 1) % points.count])
                facet.closeSubpath()
                context.addPath(facet)
                context.setFillColor(UIColor(white: index < 6 ? 0.36 : 0.05, alpha: 0.70).cgColor)
                context.fillPath()
                context.addPath(facet)
                context.setStrokeColor(UIColor(white: 0.48, alpha: 0.25).cgColor)
                context.setLineWidth(0.5)
                context.strokePath()
            }

            let crack = CGMutablePath()
            crack.move(to: CGPoint(x: -radius * 0.5, y: radius * 0.45))
            crack.addLine(to: CGPoint(x: radius * 0.1, y: radius * 0.08))
            crack.addLine(to: CGPoint(x: -radius * 0.02, y: -radius * 0.52))
            context.addPath(crack)
            context.setStrokeColor(UIColor(white: 0.02, alpha: 0.92).cgColor)
            context.setLineWidth(max(1, radius * 0.08))
            context.strokePath()
        }
    }

    private static func outline(descriptor: ScreenTimeObstacleDescriptor, radius: CGFloat) -> [CGPoint] {
        outline(variations: variations(descriptor: descriptor), radius: radius)
    }

    private static func outline(variations: [Int], radius: CGFloat) -> [CGPoint] {
        (0 ..< 12).map { index in
            let angle = CGFloat(index) / 12 * .pi * 2
            let variation = CGFloat(variations[index]) / 100
            let scale: CGFloat = index.isMultiple(of: 3) ? 0.78 + variation : 0.90 + variation
            return CGPoint(x: cos(angle) * radius * scale, y: sin(angle) * radius * scale)
        }
    }

    private static func path(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        path.closeSubpath()
        return path
    }
}
