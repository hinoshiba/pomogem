import SpriteKit
import UIKit

/// Irregular matte obsidian (D26 (a), Docs/GemExperienceDesign.md §7.14).
/// It shares the jar's physical collision shape, but has none of the study
/// crystals' glow, rim or reward marks: a dark, softly lit rock with a few
/// broad conchoidal planes, no bright edge, no regular outline and no large
/// number. The count is a small, low-contrast engraving on the rock's lower
/// face; VoiceOver and the breakdown carry it in full.
///
/// The rock is baked once per shape into one atlas sprite (`obstacle.body`);
/// the engraved count is a second small sprite that stays upright.
enum ScreenTimeObstacleAppearance {
    static let bodyName = "obstacle.body"
    static let countName = "obstacle.count"
    /// The engraved count sits this far below the centre (× the radius).
    static let countDrop: CGFloat = 0.50

    /// Installs the rock on `node` (a pebble container that draws nothing
    /// itself) and returns the upright engraved count, if the stone has one.
    /// `textureJarScale` is the jar-wide scale the textures are baked for;
    /// the sprites stay in the node's local space.
    @MainActor
    @discardableResult
    static func apply(
        to node: SKShapeNode,
        descriptor: ScreenTimeObstacleDescriptor,
        radius: CGFloat,
        scale: CGFloat = PebbleNode.defaultArtworkScale,
        textureJarScale: CGFloat = 1
    ) -> SKSpriteNode? {
        node.path = path(through: outline(variations: variations(descriptor: descriptor), radius: radius))
        node.fillColor = .clear
        node.strokeColor = .clear
        node.lineWidth = 0
        node.glowWidth = 0
        let body = makeBodySprite(descriptor: descriptor, radius: radius, scale: scale, textureJarScale: textureJarScale)
        node.addChild(body)

        guard let text = countText(descriptor: descriptor) else { return nil }
        let count = SKSpriteNode(texture: nil, size: .zero)
        count.name = countName
        count.zPosition = 0.4
        count.blendMode = .alpha
        count.position = CGPoint(x: 0, y: -radius * countDrop)
        showCount(text, radius: radius, scale: scale, textureJarScale: textureJarScale, on: count)
        node.addChild(count)
        return count
    }

    /// The count engraved on a stone, or nil for a single ten-minute stone.
    /// The wording is the existing one (a later vocabulary pass owns it).
    static func countText(descriptor: ScreenTimeObstacleDescriptor) -> String? {
        guard descriptor.level > 0 || descriptor.isHistoryPile else { return nil }
        return descriptor.isHistoryPile ? "…" : "×\(descriptor.representedUnits.formatted())"
    }

    /// Engraving size in scene points: 6–7.5 pt type, shrunk further when
    /// the text would leave the rock's lower face.
    static func countFontSize(text: String, sceneRadius: CGFloat) -> CGFloat {
        let preferred = min(7.5, max(6, sceneRadius * 0.36))
        let chord = max(8, sceneRadius * 1.30)
        let width = GemArtwork.countEngravingSize(text: text, fontSize: preferred, style: .stone).width
        guard width > chord else { return preferred }
        return max(4.5, preferred * chord / width)
    }

    /// Shows the engraved count for the current bake scale. The sprite is
    /// sized in scene points; the pebble counter-scales it by its jar scale.
    @MainActor
    static func showCount(
        _ text: String,
        radius: CGFloat,
        scale: CGFloat,
        textureJarScale: CGFloat,
        on sprite: SKSpriteNode
    ) {
        let fontSize = countFontSize(text: text, sceneRadius: radius * textureJarScale)
        sprite.setUnscaledSize(GemArtwork.countEngravingSize(text: text, fontSize: fontSize, style: .stone))
        GemTextureAtlas.shared.show(
            GemArtwork.countEngravingTextureName(text: text, fontSize: fontSize, style: .stone, scale: scale),
            on: sprite
        ) {
            GemArtwork.countEngravingImage(text: text, fontSize: fontSize, style: .stone, scale: scale)
        }
    }

    /// The baked rock as one sprite (also used by the carry gesture's
    /// non-physical copies).
    @MainActor
    static func makeBodySprite(
        descriptor: ScreenTimeObstacleDescriptor,
        radius: CGFloat,
        scale: CGFloat,
        textureJarScale: CGFloat = 1
    ) -> SKSpriteNode {
        let sprite = SKSpriteNode(texture: nil, size: spriteSize(radius: radius))
        sprite.name = bodyName
        sprite.zPosition = 0
        showBody(descriptor: descriptor, radius: radius, scale: scale, textureJarScale: textureJarScale, on: sprite)
        return sprite
    }

    /// (Re)shows the rock baked for `radius × textureJarScale` on a sprite
    /// that keeps the local size of `radius`.
    @MainActor
    static func showBody(
        descriptor: ScreenTimeObstacleDescriptor,
        radius: CGFloat,
        scale: CGFloat,
        textureJarScale: CGFloat,
        on sprite: SKSpriteNode
    ) {
        let jarScale = max(textureJarScale, 0.01)
        let bakedRadius = radius * jarScale
        let variations = self.variations(descriptor: descriptor)
        // The bake's own size, back in local points: the rock lands on the
        // collision circle exactly at every jar scale.
        let baked = spriteSize(radius: GemArtwork.sizeBucket(radius: bakedRadius))
        sprite.setUnscaledSize(CGSize(width: baked.width / jarScale, height: baked.height / jarScale))
        GemTextureAtlas.shared.show(
            textureName(variations: variations, radius: bakedRadius, scale: scale),
            on: sprite
        ) {
            image(variations: variations, radius: bakedRadius, scale: scale)
        }
    }

    /// Twelve shape variations (0…10) from the stone's identity. Stones with
    /// equal variations and radius share one texture.
    static func variations(descriptor: ScreenTimeObstacleDescriptor) -> [Int] {
        let bytes = Array(descriptor.id.uuidString.utf8)
        return (0 ..< 12).map { Int(bytes[$0 % bytes.count] % 11) }
    }

    static func textureName(variations: [Int], radius: CGFloat, scale: CGFloat) -> String {
        let shape = variations.map(String.init).joined(separator: ".")
        return "gem.obsidian|\(shape)|r\(GemArtwork.sizeBucket(radius: radius))|x\(GemArtwork.renderScale(scale))"
    }

    /// Margin around the outline (points).
    static let margin: CGFloat = 1.5

    static func spriteSize(radius: CGFloat) -> CGSize {
        let side = (radius + margin) * 2
        return CGSize(width: side, height: side)
    }

    /// Number of outline corners (9–11) for a shape: never a regular
    /// polygon, never a chip.
    static func cornerCount(variations: [Int]) -> Int {
        9 + (variations.first ?? 0) % 3
    }

    /// Core Graphics bake of the rock: a dark cool fill, three to five broad
    /// planes lit only a little from the upper left, faint conchoidal
    /// ripples, a matte grain and a soft shade toward the floor. The
    /// brightest pixel stays near the jar's own glass tint (matte, never a
    /// highlight). Thread-safe.
    static func image(variations: [Int], radius rawRadius: CGFloat, scale: CGFloat) -> UIImage {
        let radius = GemArtwork.sizeBucket(radius: rawRadius)
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
            context.setLineJoin(.round)

            let points = outline(variations: variations, radius: radius)
            let outlinePath = path(through: points)
            context.saveGState()
            context.addPath(outlinePath)
            context.clip()

            // Base: near-black, slightly cool, lit a little from the top.
            let top = UIColor(red: 0.135, green: 0.130, blue: 0.160, alpha: 1)
            let bottom = UIColor(red: 0.045, green: 0.043, blue: 0.055, alpha: 1)
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [top.cgColor, bottom.cgColor] as CFArray,
                locations: [0, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: -radius * 0.45, y: radius),
                    end: CGPoint(x: radius * 0.30, y: -radius),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }

            // Broad planes from an off-centre ridge, each spanning two to
            // four outline edges. Their value follows the light a little.
            var random = GemRandom(seed: UInt64(variations.reduce(7) { $0 &* 31 &+ $1 }))
            let ridge = CGPoint(
                x: -radius * (0.10 + random.unit() * 0.16),
                y: radius * (0.04 + random.unit() * 0.14)
            )
            let light = CGPoint(x: -0.62, y: 0.78)
            var index = 0
            while index < points.count {
                let span = 2 + Int(random.next() % 3)
                let end = min(points.count, index + span)
                let facet = CGMutablePath()
                facet.move(to: ridge)
                for corner in index ... end {
                    facet.addLine(to: points[corner % points.count])
                }
                facet.closeSubpath()
                let mid = points[(index + end) / 2 % points.count]
                let direction = CGPoint(x: mid.x - ridge.x, y: mid.y - ridge.y)
                let length = max(0.001, hypot(direction.x, direction.y))
                let facing = (direction.x * light.x + direction.y * light.y) / length
                let value = 0.10 + 0.05 * facing + (random.unit() - 0.5) * 0.02
                context.addPath(facet)
                context.setFillColor(UIColor(red: value * 0.98, green: value * 0.96, blue: value * 1.12, alpha: 0.55).cgColor)
                context.fillPath()
                // A dark seam between planes, barely visible.
                context.addPath(facet)
                context.setStrokeColor(UIColor(white: 0, alpha: 0.28).cgColor)
                context.setLineWidth(max(0.4, radius * 0.025))
                context.strokePath()
                index = end
            }

            // Conchoidal ripples: two or three faint arcs around the ridge.
            for ripple in 0 ..< 2 + Int(random.next() % 2) {
                let arcRadius = radius * (0.34 + CGFloat(ripple) * 0.20 + random.unit() * 0.06)
                let start = CGFloat.pi * (0.35 + random.unit() * 0.30)
                context.addArc(
                    center: ridge,
                    radius: arcRadius,
                    startAngle: start,
                    endAngle: start + .pi * (0.45 + random.unit() * 0.25),
                    clockwise: false
                )
                context.setStrokeColor(UIColor(white: 1, alpha: 0.045).cgColor)
                context.setLineWidth(max(0.4, radius * 0.03))
                context.strokePath()
            }

            // Matte grain.
            for _ in 0 ..< Int(radius * 3) {
                let angle = random.unit() * .pi * 2
                let distance = sqrt(random.unit()) * radius * 0.92
                let dot = max(0.35, radius * 0.022)
                context.setFillColor(UIColor(white: random.next() % 3 == 0 ? 1 : 0, alpha: 0.05).cgColor)
                context.fillEllipse(in: CGRect(
                    x: cos(angle) * distance - dot / 2,
                    y: sin(angle) * distance - dot / 2,
                    width: dot,
                    height: dot
                ))
            }

            // Soft shade toward the floor (the rock sits in its own shadow).
            if let shade = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor(white: 0, alpha: 0).cgColor, UIColor(white: 0, alpha: 0.45).cgColor] as CFArray,
                locations: [0.45, 1]
            ) {
                context.drawLinearGradient(
                    shade,
                    start: CGPoint(x: 0, y: radius),
                    end: CGPoint(x: 0, y: -radius),
                    options: []
                )
            }
            context.restoreGState()

            // No rim: only the upper-left edge catches a trace of the jar's
            // light, so the rock separates from the dark glass without a
            // chip-like border.
            context.saveGState()
            context.addPath(outlinePath)
            context.setLineWidth(max(0.7, radius * 0.06))
            context.replacePathWithStrokedPath()
            context.clip()
            if let rim = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor(white: 0.62, alpha: 0.22).cgColor, UIColor(white: 0.62, alpha: 0).cgColor] as CFArray,
                locations: [0, 1]
            ) {
                context.drawLinearGradient(
                    rim,
                    start: CGPoint(x: -radius * 0.7, y: radius * 0.7),
                    end: CGPoint(x: radius * 0.2, y: -radius * 0.2),
                    options: []
                )
            }
            context.restoreGState()
        }
    }

    /// Outline points (scene space, y up): 9–11 corners at uneven angles
    /// and radii (0.80–0.98 of the collision radius), so no two stones and
    /// no stone and a coin share a silhouette.
    static func outline(variations: [Int], radius: CGFloat) -> [CGPoint] {
        let count = cornerCount(variations: variations)
        let step = CGFloat.pi * 2 / CGFloat(count)
        let phase = CGFloat(variations[1 % variations.count]) / 10 * step
        return (0 ..< count).map { index in
            let jitter = (CGFloat(variations[(index + 2) % variations.count]) / 10 - 0.5) * step * 0.55
            let angle = phase + CGFloat(index) * step + jitter
            let reach = 0.80 + CGFloat(variations[(index * 5 + 3) % variations.count]) / 10 * 0.18
            return CGPoint(x: cos(angle) * radius * reach, y: sin(angle) * radius * reach)
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
