import SpriteKit
import UIKit

/// Visual cut used to draw one study gem. The cut is presentation only: it
/// never changes the circular physics body, the mass-derived radius, or any
/// persisted value. A later design pass can remap tiers through
/// `GemCutLadder` without touching the renderer.
enum GemCut: String, CaseIterable, Sendable {
    /// Loose measured gem: a softly irregular, many-faceted tumbled stone.
    case tumbled
    /// Self-reported gem: a simpler, lower-contrast rough cut. Its dashed
    /// ring keeps the measured/self-reported distinction readable.
    case rough
    /// Zero-mass tutorial gem: colourless glass.
    case glass
    /// ×10: octagonal step cut with a large mirror-like table.
    case step
    /// ×100: classic round brilliant (table, star, kite and girdle facets).
    case brilliant
    /// ×1000 and above: a multi-colour radiant brilliant with a white core.
    case radiant
    /// The lifetime "time core": a clean decagonal hero stone with a central
    /// star fan and a girdle band, painted as a dispersion fan.
    case hero
}

/// Light budget for one tier. Every value is deterministic; brilliance grows
/// only with recorded effort, never with chance.
struct GemCutRung: Equatable, Sendable {
    var cut: GemCut
    /// Rotational symmetry of the facet layout (outline vertex basis).
    var symmetry: Int
    /// Halo sprite diameter as a multiple of the gem diameter.
    var haloScale: CGFloat
    var haloAlpha: CGFloat
    /// Dynamic star glints that respond to tilt and twinkle.
    var glintCount: Int
    /// Glint sprite size as a multiple of the gem radius.
    var glintScale: CGFloat
    /// Tiny static sparkles baked into the facet texture.
    var sparkleCount: Int
    /// 0...1 strength of the per-facet light/dark scintillation pattern.
    var facetContrast: CGFloat
}

/// The single table that maps the existing decimal hierarchy to cuts.
struct GemCutLadder: Sendable {
    var loose: GemCutRung
    var selfReported: GemCutRung
    var tutorial: GemCutRung
    /// Index 0 is ×10 (level 1). Deeper levels reuse the last rung.
    var aggregates: [GemCutRung]

    static let standard = GemCutLadder(
        loose: GemCutRung(
            cut: .tumbled, symmetry: 12, haloScale: 2.5, haloAlpha: 0.72,
            glintCount: 1, glintScale: 1.35, sparkleCount: 2, facetContrast: 0.85
        ),
        selfReported: GemCutRung(
            cut: .rough, symmetry: 8, haloScale: 2.0, haloAlpha: 0.30,
            glintCount: 0, glintScale: 0, sparkleCount: 0, facetContrast: 0.40
        ),
        tutorial: GemCutRung(
            cut: .glass, symmetry: 12, haloScale: 1.8, haloAlpha: 0.08,
            glintCount: 0, glintScale: 0, sparkleCount: 1, facetContrast: 0.35
        ),
        aggregates: [
            GemCutRung(
                cut: .step, symmetry: 8, haloScale: 2.5, haloAlpha: 0.76,
                glintCount: 1, glintScale: 1.05, sparkleCount: 2, facetContrast: 0.75
            ),
            GemCutRung(
                cut: .brilliant, symmetry: 8, haloScale: 2.6, haloAlpha: 0.82,
                glintCount: 2, glintScale: 1.1, sparkleCount: 3, facetContrast: 0.95
            ),
            GemCutRung(
                cut: .radiant, symmetry: 10, haloScale: 2.7, haloAlpha: 0.88,
                glintCount: 3, glintScale: 1.15, sparkleCount: 4, facetContrast: 0.72
            ),
            GemCutRung(
                cut: .radiant, symmetry: 12, haloScale: 2.8, haloAlpha: 0.92,
                glintCount: 3, glintScale: 1.2, sparkleCount: 5, facetContrast: 0.72
            )
        ]
    )

    func rung(aggregateLevel: Int) -> GemCutRung {
        guard !aggregates.isEmpty else { return loose }
        let index = min(max(aggregateLevel, 1), aggregates.count) - 1
        return aggregates[index]
    }

    func rung(for descriptor: PebbleDescriptor) -> GemCutRung {
        if let aggregate = descriptor.aggregate {
            return rung(aggregateLevel: aggregate.level)
        }
        if descriptor.isTutorial { return tutorial }
        return descriptor.isMeasured ? loose : selfReported
    }
}

/// Colour share used to paint facets by angular sector, clockwise from 12
/// o'clock. A single entry paints a monochrome gem.
struct GemColorShare: Hashable, Sendable {
    let hex: String
    let fraction: Double
}

/// Everything that affects a baked facet texture. Hashable so equal gems
/// share one cached texture.
struct GemArtworkSpec: Hashable, Sendable {
    let cut: GemCut
    let symmetry: Int
    let colors: [GemColorShare]
    let variant: Int
    let facetContrast: CGFloat
    let sparkleCount: Int
    /// Reduces saturation for self-reported effort (existing convention).
    let isMuted: Bool
    let showsDashedRing: Bool

    static let variantCount = 4

    var cacheKey: String {
        let palette = colors
            .map { "\($0.hex.uppercased())@\(Int(($0.fraction * 20).rounded()))" }
            .joined(separator: ",")
        return [
            cut.rawValue,
            "\(symmetry)",
            palette,
            "v\(variant)",
            "c\(Int((facetContrast * 20).rounded()))",
            "s\(sparkleCount)",
            isMuted ? "m" : "f",
            showsDashedRing ? "d" : "-"
        ].joined(separator: "|")
    }
}

/// Core Graphics renderer for faceted gems. All textures are baked once per
/// (spec, size bucket, screen scale) and cached; nothing here runs per frame.
enum GemArtwork {
    // MARK: Public entry points

    /// Unit-space (radius 1, y up) outline shared by the texture and the
    /// optional SKShapeNode rim, so both always agree exactly.
    static func outline(cut: GemCut, symmetry: Int, variant: Int) -> [CGPoint] {
        switch cut {
        case .tumbled, .glass:
            return tumbledLayout(symmetry: symmetry, variant: variant).outer
        case .rough:
            return roughLayout(symmetry: symmetry, variant: variant).outer
        case .step:
            return stepRing(symmetry: symmetry, scale: 1)
        case .brilliant, .radiant:
            return brilliantLayout(symmetry: symmetry).girdle
        case .hero:
            return heroLayout(symmetry: symmetry).outer
        }
    }

    static func outlinePath(for spec: GemArtworkSpec, radius: CGFloat) -> CGPath {
        let points = outline(cut: spec.cut, symmetry: spec.symmetry, variant: spec.variant)
        let path = CGMutablePath()
        guard let first = points.first else {
            return CGPath(
                ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2),
                transform: nil
            )
        }
        path.move(to: CGPoint(x: first.x * radius, y: first.y * radius))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * radius, y: point.y * radius))
        }
        path.closeSubpath()
        return path
    }

    /// Texture size in points for a gem of `radius`, including the thin
    /// outline stroke margin. The sprite must use this size.
    static func bodySpriteSize(radius: CGFloat) -> CGSize {
        let side = (radius + margin(radius: radius)) * 2
        return CGSize(width: side, height: side)
    }

    static func bodyTexture(for spec: GemArtworkSpec, radius: CGFloat) -> SKTexture {
        let bucket = sizeBucket(radius: radius)
        let scale = renderScale
        let key = NSString(string: "\(spec.cacheKey)|r\(bucket)|x\(scale)")
        if let cached = bodyCache.object(forKey: key) { return cached }
        let image = renderBody(spec: spec, radius: bucket, scale: scale)
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        let pixels = Int(image.size.width * image.scale * image.size.height * image.scale)
        bodyCache.setObject(texture, forKey: key, cost: pixels * 4)
        return texture
    }

    /// The same renderer as a SwiftUI/UIKit image (share cards, overview).
    static func bodyImage(for spec: GemArtworkSpec, radius: CGFloat) -> UIImage {
        let bucket = sizeBucket(radius: radius)
        let scale = renderScale
        let key = NSString(string: "\(spec.cacheKey)|r\(bucket)|x\(scale)")
        if let cached = imageCache.object(forKey: key) { return cached }
        let image = renderBody(spec: spec, radius: bucket, scale: scale)
        imageCache.setObject(image, forKey: key)
        return image
    }

    /// Hero "time core": radiant cut with a dispersion palette anchored on
    /// the mass-weighted effort colour. Deterministic for (colour, level).
    static func coreImage(colorHex: String, level: Int, diameter: CGFloat) -> UIImage {
        let bucket = max(24, (diameter / 16).rounded(.up) * 16)
        let symmetry = level >= 3 ? 12 : 10
        let key = NSString(string: "core|\(colorHex.uppercased())|\(symmetry)|\(min(level, 6))|\(bucket)|x\(renderScale)")
        if let cached = imageCache.object(forKey: key) { return cached }
        let anchor = GemColor(hex: colorHex)
        let spec = GemArtworkSpec(
            cut: .hero,
            symmetry: symmetry,
            colors: [GemColorShare(hex: colorHex, fraction: 1)],
            variant: 0,
            facetContrast: 1,
            sparkleCount: 2,
            isMuted: false,
            showsDashedRing: false
        )
        let image = renderBody(
            spec: spec,
            radius: bucket / 2 - margin(radius: bucket / 2),
            scale: renderScale,
            dispersionAnchor: anchor,
            coreStarStrength: min(1, 0.72 + CGFloat(max(0, level - 1)) * 0.07)
        )
        imageCache.setObject(image, forKey: key)
        return image
    }

    // MARK: Shared light textures (one draw batch each)

    /// Soft additive bloom. Tinted per gem with `color` + `colorBlendFactor`.
    static let haloTexture: SKTexture = sharedTexture(pixels: 128) { context, size in
        let center = CGPoint(x: size / 2, y: size / 2)
        let colors = [
            UIColor(white: 1, alpha: 1).cgColor,
            UIColor(white: 1, alpha: 0.80).cgColor,
            UIColor(white: 1, alpha: 0.36).cgColor,
            UIColor(white: 1, alpha: 0.11).cgColor,
            UIColor(white: 1, alpha: 0).cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.36, 0.50, 0.72, 1]
        ) {
            context.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: size / 2,
                options: []
            )
        }
    }

    /// Four-point star with a soft core; additive, white.
    static let glintTexture: SKTexture = sharedTexture(pixels: 128) { context, size in
        let center = CGPoint(x: size / 2, y: size / 2)
        let space = CGColorSpaceCreateDeviceRGB()
        let core = [
            UIColor(white: 1, alpha: 1).cgColor,
            UIColor(white: 1, alpha: 0.35).cgColor,
            UIColor(white: 1, alpha: 0).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: core, locations: [0, 0.35, 1]) {
            context.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: size * 0.16,
                options: []
            )
        }
        func ray(length: CGFloat, width: CGFloat, angle: CGFloat, alpha: CGFloat) {
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: angle)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -length, y: 0))
            path.addQuadCurve(to: CGPoint(x: length, y: 0), control: CGPoint(x: 0, y: width))
            path.addQuadCurve(to: CGPoint(x: -length, y: 0), control: CGPoint(x: 0, y: -width))
            context.addPath(path)
            context.clip()
            let colors = [
                UIColor(white: 1, alpha: alpha).cgColor,
                UIColor(white: 1, alpha: 0).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                context.drawRadialGradient(
                    gradient,
                    startCenter: .zero, startRadius: 0,
                    endCenter: .zero, endRadius: length,
                    options: []
                )
            }
            context.restoreGState()
        }
        ray(length: size * 0.5, width: size * 0.05, angle: 0, alpha: 1)
        ray(length: size * 0.5, width: size * 0.05, angle: .pi / 2, alpha: 1)
        ray(length: size * 0.26, width: size * 0.03, angle: .pi / 4, alpha: 0.55)
        ray(length: size * 0.26, width: size * 0.03, angle: -.pi / 4, alpha: 0.55)
    }

    /// Soft contact shadow ellipse drawn in a square; the sprite squashes it.
    static let shadowTexture: SKTexture = sharedTexture(pixels: 64) { context, size in
        let center = CGPoint(x: size / 2, y: size / 2)
        let colors = [
            UIColor(red: 0.01, green: 0.02, blue: 0.06, alpha: 0.82).cgColor,
            UIColor(red: 0.01, green: 0.02, blue: 0.06, alpha: 0.34).cgColor,
            UIColor(red: 0.01, green: 0.02, blue: 0.06, alpha: 0).cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.5, 1]
        ) {
            context.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: size / 2,
                options: []
            )
        }
    }

    /// Screen-fixed key light: a warm specular sheen at the upper left and a
    /// gentle pavilion shade at the lower right. Shared by every gem.
    static let keyLightTexture: SKTexture = sharedTexture(pixels: 128) { context, size in
        let space = CGColorSpaceCreateDeviceRGB()
        let radius = size / 2
        context.saveGState()
        context.addEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        context.clip()

        let shade = [
            UIColor(red: 0.02, green: 0.02, blue: 0.10, alpha: 0).cgColor,
            UIColor(red: 0.02, green: 0.02, blue: 0.10, alpha: 0.30).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: shade, locations: [0, 1]) {
            context.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: radius * 0.72, y: radius * 0.66),
                startRadius: radius * 0.35,
                endCenter: CGPoint(x: radius * 0.86, y: radius * 0.80),
                endRadius: radius * 1.28,
                options: [.drawsAfterEndLocation]
            )
        }

        let sheen = [
            UIColor(red: 1, green: 0.95, blue: 0.90, alpha: 0.46).cgColor,
            UIColor(red: 1, green: 0.90, blue: 0.84, alpha: 0.12).cgColor,
            UIColor(white: 1, alpha: 0).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: sheen, locations: [0, 0.45, 1]) {
            context.saveGState()
            context.translateBy(x: radius * 0.60, y: radius * 0.52)
            context.rotate(by: -.pi / 5)
            context.scaleBy(x: 1.55, y: 0.78)
            context.drawRadialGradient(
                gradient,
                startCenter: .zero, startRadius: 0,
                endCenter: .zero, endRadius: radius * 0.42,
                options: []
            )
            context.restoreGState()
        }

        // Cool bounce light on the lower-left rim separates touching gems.
        let bounce = [
            UIColor(red: 0.55, green: 0.82, blue: 1, alpha: 0.22).cgColor,
            UIColor(red: 0.55, green: 0.82, blue: 1, alpha: 0).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: bounce, locations: [0, 1]) {
            context.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: radius * 0.45, y: radius * 1.72),
                startRadius: 0,
                endCenter: CGPoint(x: radius * 0.45, y: radius * 1.72),
                endRadius: radius * 0.72,
                options: []
            )
        }
        context.restoreGState()
    }

    // MARK: Cache and sizing

    private static let bodyCache: NSCache<NSString, SKTexture> = {
        let cache = NSCache<NSString, SKTexture>()
        cache.name = "PomoGem.GemArtwork.body"
        cache.countLimit = 256
        cache.totalCostLimit = 48 * 1_024 * 1_024
        return cache
    }()

    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.name = "PomoGem.GemArtwork.image"
        cache.countLimit = 48
        return cache
    }()

    private static var renderScale: CGFloat {
        min(3, max(1, UIScreen.main.scale))
    }

    /// 1pt buckets below 16pt, 2pt above. Loose radii vary continuously with
    /// mass, so bucketing is what makes the cache hit.
    static func sizeBucket(radius: CGFloat) -> CGFloat {
        let clamped = max(4, radius)
        if clamped < 16 { return clamped.rounded(.up) }
        return (clamped / 2).rounded(.up) * 2
    }

    private static func margin(radius: CGFloat) -> CGFloat {
        max(1.5, radius * 0.06)
    }

    private static func sharedTexture(
        pixels: Int,
        draw: (CGContext, CGFloat) -> Void
    ) -> SKTexture {
        let size = CGFloat(pixels)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: size, height: size),
            format: format
        ).image { renderer in
            draw(renderer.cgContext, size)
        }
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        return texture
    }

    // MARK: Layouts (unit space, y up)

    private struct Facet {
        var points: [CGPoint]
        /// 0 = flat table, 1 = steep girdle.
        var slope: CGFloat
        /// Pavilion reflections read through the table flip the light.
        var isTable = false
        /// True 3D facet normal (geodesic cuts); nil derives one from slope.
        var normal: (x: CGFloat, y: CGFloat, z: CGFloat)?
    }

    private struct TumbledLayout {
        let outer: [CGPoint]
        let facets: [Facet]
    }

    /// Loose gems are geodesic crystals: a subdivided icosahedron, rotated
    /// per variant and seen orthographically. Every facet carries its real
    /// normal, so lighting and the Fresnel rim are physically coherent. The
    /// silhouette is the convex hull of the projected vertices, which always
    /// lies inside the unit (physics) circle.
    private static func tumbledLayout(symmetry: Int, variant: Int) -> TumbledLayout {
        geodesicLayout(frequency: 2, variant: variant, salt: 0x6E4D)
    }

    /// Self-reported gems: the plain icosahedron — fewer, larger facets.
    private static func roughLayout(symmetry: Int, variant: Int) -> TumbledLayout {
        geodesicLayout(frequency: 1, variant: variant, salt: 0x2B0B)
    }

    private static let layoutLock = NSLock()
    nonisolated(unsafe) private static var layoutCache: [String: TumbledLayout] = [:]

    private static func geodesicLayout(frequency: Int, variant: Int, salt: Int) -> TumbledLayout {
        let key = "\(frequency)-\(variant)-\(salt)"
        layoutLock.lock()
        if let cached = layoutCache[key] {
            layoutLock.unlock()
            return cached
        }
        layoutLock.unlock()

        let mesh = icosphere(frequency: frequency)
        var random = GemRandom(seed: UInt64(salt &* 7_919 &+ variant &* 104_729 &+ 17))
        let yaw = random.unit() * .pi * 2
        let pitch = (random.unit() - 0.5) * 1.1
        let roll = random.unit() * .pi * 2
        func rotate(_ v: (CGFloat, CGFloat, CGFloat)) -> (x: CGFloat, y: CGFloat, z: CGFloat) {
            // roll (z), pitch (x), yaw (y)
            var (x, y, z) = v
            (x, y) = (x * cos(roll) - y * sin(roll), x * sin(roll) + y * cos(roll))
            (y, z) = (y * cos(pitch) - z * sin(pitch), y * sin(pitch) + z * cos(pitch))
            (x, z) = (x * cos(yaw) + z * sin(yaw), -x * sin(yaw) + z * cos(yaw))
            return (x, y, z)
        }
        let vertices = mesh.vertices.map(rotate)
        var facets: [Facet] = []
        for face in mesh.faces {
            let a = vertices[face.0], b = vertices[face.1], c = vertices[face.2]
            let u = (b.x - a.x, b.y - a.y, b.z - a.z)
            let v = (c.x - a.x, c.y - a.y, c.z - a.z)
            var n = (
                x: u.1 * v.2 - u.2 * v.1,
                y: u.2 * v.0 - u.0 * v.2,
                z: u.0 * v.1 - u.1 * v.0
            )
            let length = max(sqrt(n.x * n.x + n.y * n.y + n.z * n.z), 0.000_1)
            n = (n.x / length, n.y / length, n.z / length)
            // Outward orientation: the centroid direction of a convex hull.
            let centroid = ((a.x + b.x + c.x) / 3, (a.y + b.y + c.y) / 3, (a.z + b.z + c.z) / 3)
            if n.x * centroid.0 + n.y * centroid.1 + n.z * centroid.2 < 0 {
                n = (-n.x, -n.y, -n.z)
            }
            guard n.z > 0.02 else { continue }
            facets.append(Facet(
                points: [CGPoint(x: a.x, y: a.y), CGPoint(x: b.x, y: b.y), CGPoint(x: c.x, y: c.y)],
                slope: 1 - n.z,
                isTable: n.z > 0.93,
                normal: n
            ))
        }
        let hull = convexHull(vertices.map { CGPoint(x: $0.x, y: $0.y) })
        let layout = TumbledLayout(outer: hull, facets: facets)
        layoutLock.lock()
        layoutCache[key] = layout
        layoutLock.unlock()
        return layout
    }

    private static func icosphere(frequency: Int) -> (vertices: [(CGFloat, CGFloat, CGFloat)], faces: [(Int, Int, Int)]) {
        let t = (1 + sqrt(CGFloat(5))) / 2
        var vertices: [(CGFloat, CGFloat, CGFloat)] = [
            (-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0),
            (0, -1, t), (0, 1, t), (0, -1, -t), (0, 1, -t),
            (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)
        ].map { normalized($0) }
        var faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)
        ]
        for _ in 1 ..< max(1, frequency) {
            var midpointCache: [Int: Int] = [:]
            func midpoint(_ i: Int, _ j: Int) -> Int {
                let key = min(i, j) << 16 | max(i, j)
                if let cached = midpointCache[key] { return cached }
                let a = vertices[i], b = vertices[j]
                vertices.append(normalized(((a.0 + b.0) / 2, (a.1 + b.1) / 2, (a.2 + b.2) / 2)))
                midpointCache[key] = vertices.count - 1
                return vertices.count - 1
            }
            var next: [(Int, Int, Int)] = []
            for face in faces {
                let ab = midpoint(face.0, face.1)
                let bc = midpoint(face.1, face.2)
                let ca = midpoint(face.2, face.0)
                next.append((face.0, ab, ca))
                next.append((face.1, bc, ab))
                next.append((face.2, ca, bc))
                next.append((ab, bc, ca))
            }
            faces = next
        }
        return (vertices, faces)
    }

    private static func normalized(_ v: (CGFloat, CGFloat, CGFloat)) -> (CGFloat, CGFloat, CGFloat) {
        let length = max(sqrt(v.0 * v.0 + v.1 * v.1 + v.2 * v.2), 0.000_1)
        return (v.0 / length, v.1 / length, v.2 / length)
    }

    /// Andrew's monotone chain; counter-clockwise in y-up space.
    private static func convexHull(_ raw: [CGPoint]) -> [CGPoint] {
        let points = raw.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard points.count > 2 else { return points }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for point in points {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0.000_1 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [CGPoint] = []
        for point in points.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0.000_1 {
                upper.removeLast()
            }
            upper.append(point)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    private static func stepRing(symmetry rawSymmetry: Int, scale: CGFloat) -> [CGPoint] {
        let count = max(6, rawSymmetry)
        let offset = CGFloat.pi / CGFloat(count)
        return (0 ..< count).map { index in
            let angle = CGFloat.pi / 2 + offset + CGFloat(index) / CGFloat(count) * .pi * 2
            return CGPoint(x: cos(angle) * scale, y: sin(angle) * scale)
        }
    }

    private static func stepFacets(symmetry: Int) -> [Facet] {
        let scales: [CGFloat] = [1, 0.80, 0.62, 0.46]
        let slopes: [CGFloat] = [0.86, 0.62, 0.38]
        let rings = scales.map { stepRing(symmetry: symmetry, scale: $0) }
        var facets: [Facet] = []
        for band in 0 ..< 3 {
            let outer = rings[band]
            let inner = rings[band + 1]
            for index in outer.indices {
                let next = (index + 1) % outer.count
                facets.append(Facet(
                    points: [outer[index], outer[next], inner[next], inner[index]],
                    slope: slopes[band]
                ))
            }
        }
        // One large mirror table; the streaks drawn later give it depth.
        facets.append(Facet(points: rings[3], slope: 0.05, isTable: true))
        return facets
    }

    private struct HeroLayout {
        let outer: [CGPoint]
        let facets: [Facet]
    }

    private static func heroLayout(symmetry rawSymmetry: Int) -> HeroLayout {
        let count = max(6, rawSymmetry)
        let step = CGFloat.pi * 2 / CGFloat(count)
        func polar(_ angle: CGFloat, _ radius: CGFloat) -> CGPoint {
            CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        let outer = (0 ..< count).map { polar(.pi / 2 + CGFloat($0) * step, 1) }
        let inner = (0 ..< count).map { polar(.pi / 2 + (CGFloat($0) + 0.5) * step, 0.80) }
        let center = CGPoint.zero
        var facets: [Facet] = []
        for index in 0 ..< count {
            let next = (index + 1) % count
            let previous = (index + count - 1) % count
            // Central star: two half-fans per outer vertex direction.
            facets.append(Facet(points: [center, inner[previous], outer[index]], slope: 0.22, isTable: true))
            facets.append(Facet(points: [center, outer[index], inner[index]], slope: 0.22, isTable: true))
            // Girdle band.
            facets.append(Facet(points: [outer[index], outer[next], inner[index]], slope: 0.86))
        }
        return HeroLayout(outer: outer, facets: facets)
    }

    private struct BrilliantLayout {
        let girdle: [CGPoint]
        let table: [CGPoint]
        let facets: [Facet]
    }

    private static func brilliantLayout(symmetry rawSymmetry: Int) -> BrilliantLayout {
        let count = max(6, rawSymmetry)
        let step = CGFloat.pi * 2 / CGFloat(count)
        let start = CGFloat.pi / 2
        func polar(_ angle: CGFloat, _ radius: CGFloat) -> CGPoint {
            CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        let table = (0 ..< count).map { polar(start + CGFloat($0) * step, 0.50) }
        let stars = (0 ..< count).map { polar(start + (CGFloat($0) + 0.5) * step, 0.77) }
        let girdle = (0 ..< count * 2).map { polar(start + CGFloat($0) * step / 2, 1) }
        let center = CGPoint(x: 0, y: 0)
        var facets: [Facet] = []
        for index in 0 ..< count {
            let next = (index + 1) % count
            let previous = (index + count - 1) % count
            facets.append(Facet(points: [center, table[index], table[next]], slope: 0.10, isTable: true))
            facets.append(Facet(points: [table[index], table[next], stars[index]], slope: 0.36))
            facets.append(Facet(
                points: [table[index], stars[previous], girdle[index * 2], stars[index]],
                slope: 0.60
            ))
            facets.append(Facet(
                points: [stars[index], girdle[index * 2], girdle[index * 2 + 1]],
                slope: 0.86
            ))
            facets.append(Facet(
                points: [stars[index], girdle[index * 2 + 1], girdle[(index * 2 + 2) % (count * 2)]],
                slope: 0.86
            ))
        }
        return BrilliantLayout(girdle: girdle, table: table, facets: facets)
    }

    // MARK: Rendering

    private static let keyLight: (x: CGFloat, y: CGFloat, z: CGFloat) = {
        let raw = (x: CGFloat(-0.45), y: CGFloat(0.55), z: CGFloat(0.70))
        let length = sqrt(raw.x * raw.x + raw.y * raw.y + raw.z * raw.z)
        return (raw.x / length, raw.y / length, raw.z / length)
    }()

    private static func renderBody(
        spec: GemArtworkSpec,
        radius: CGFloat,
        scale: CGFloat,
        dispersionAnchor: GemColor? = nil,
        coreStarStrength: CGFloat = 0
    ) -> UIImage {
        let pad = margin(radius: radius)
        let side = (radius + pad) * 2
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = scale
        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        ).image { renderer in
            let context = renderer.cgContext
            let center = CGPoint(x: side / 2, y: side / 2)
            // Unit space is y-up; UIKit image space is y-down.
            func map(_ point: CGPoint) -> CGPoint {
                CGPoint(x: center.x + point.x * radius, y: center.y - point.y * radius)
            }
            drawGem(
                spec: spec,
                context: context,
                radius: radius,
                map: map,
                dispersionAnchor: dispersionAnchor,
                coreStarStrength: coreStarStrength
            )
        }
    }

    private static func facets(for spec: GemArtworkSpec) -> [Facet] {
        switch spec.cut {
        case .tumbled, .glass:
            return tumbledLayout(symmetry: spec.symmetry, variant: spec.variant).facets
        case .rough:
            return roughLayout(symmetry: spec.symmetry, variant: spec.variant).facets
        case .step:
            return stepFacets(symmetry: spec.symmetry)
        case .brilliant, .radiant:
            return brilliantLayout(symmetry: spec.symmetry).facets
        case .hero:
            return heroLayout(symmetry: spec.symmetry).facets
        }
    }

    // swiftlint:disable:next function_body_length
    private static func drawGem(
        spec: GemArtworkSpec,
        context: CGContext,
        radius: CGFloat,
        map: (CGPoint) -> CGPoint,
        dispersionAnchor: GemColor?,
        coreStarStrength: CGFloat
    ) {
        let space = CGColorSpaceCreateDeviceRGB()
        let outlinePoints = outline(cut: spec.cut, symmetry: spec.symmetry, variant: spec.variant)
        let outlinePath = CGMutablePath()
        outlinePath.addLines(between: outlinePoints.map(map))
        outlinePath.closeSubpath()

        let palette = sectorPalette(spec: spec, dispersionAnchor: dispersionAnchor)
        let isGlass = spec.cut == .glass
        let isRadiant = spec.cut == .radiant || spec.cut == .hero
        let isHero = spec.cut == .hero
        let contrast = min(max(spec.facetContrast, 0), 1)
        var random = GemRandom(seed: UInt64(0x5EED + spec.variant * 7_919 + spec.symmetry * 131))

        context.saveGState()
        context.addPath(outlinePath)
        context.clip()

        // 1. Body fill: the deep tone shows through hairline gaps.
        let meanColor = palette.color(atAngle: .pi / 2)
        context.setFillColor(meanColor.shaded(0.34, muted: spec.isMuted, glass: isGlass).cgColor)
        context.addPath(outlinePath)
        context.fillPath()

        // 2. Facets: pseudo-normal lighting + deterministic scintillation.
        let facetList = facets(for: spec)
        let light = keyLight
        for (index, facet) in facetList.enumerated() {
            let centroid = facet.points.reduce(CGPoint.zero) {
                CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
            }
            let c = CGPoint(
                x: centroid.x / CGFloat(facet.points.count),
                y: centroid.y / CGFloat(facet.points.count)
            )
            let direction = atan2(c.y, c.x)
            let tilt = facet.slope * .pi / 2.9
            let normal = facet.normal ?? (
                x: cos(direction) * sin(tilt),
                y: sin(direction) * sin(tilt),
                z: cos(tilt)
            )
            let direct = max(0, normal.x * light.x + normal.y * light.y + normal.z * light.z)
            // Light entering the crown bounces off the pavilion and exits on
            // the opposite side: the reason real gems glow at the lower rim.
            let bounce = max(0, -normal.x * light.x - normal.y * light.y) * facet.slope
            let noise = random.unit() - 0.5
            let flash = random.unit()
            var brightness: CGFloat
            if isHero {
                // Clean glassy fan: gentle alternation, bright table star.
                let alternate: CGFloat = index.isMultiple(of: 2) ? 0.08 : -0.06
                brightness = (facet.isTable ? 0.40 : 0.30) + 0.30 * direct
                    + alternate + 0.08 * noise + 0.26 * bounce
            } else if facet.normal != nil {
                // Geodesic crystal: luminous body, bright Fresnel rim, and a
                // gentle scintillation pattern — lit from within, not matte.
                let fresnel = pow(max(0, 1 - normal.z), 1.5)
                brightness = 0.30 + 0.40 * pow(direct, 1.4) + 0.26 * bounce
                    + 0.46 * fresnel + contrast * 0.34 * noise
            } else {
                brightness = 0.17 + 0.52 * pow(direct, 1.6) + 0.46 * bounce
                    + contrast * 0.62 * noise
            }
            if facet.isTable, facet.normal == nil, !isHero {
                // Table triangles alternate like pavilion mains seen through
                // the top: the star pattern that reads as a cut stone.
                brightness = (index / 3).isMultiple(of: 2) || spec.cut == .step
                    ? brightness * 0.78 + 0.22
                    : brightness * 0.62
                if spec.cut == .brilliant || spec.cut == .radiant {
                    brightness = (index / 5).isMultiple(of: 2) ? 0.88 : 0.42
                    brightness += noise * 0.2 * contrast
                }
            }
            let isFlash = flash > (isHero ? 0.93 : (isRadiant ? 0.80 : 0.88)) && !spec.isMuted
            if isFlash { brightness = max(brightness, 0.93) }
            brightness = min(max(brightness, 0.06), 1)

            let hueJitter = (random.unit() - 0.5) * (isRadiant ? 0.03 : 0.045)
            var color = palette.color(atAngle: direction)
                .facet(brightness: brightness, hueShift: hueJitter, muted: spec.isMuted, glass: isGlass)
            if isFlash {
                let tints = [GemColor.fireWarm, GemColor.fireCool, GemColor.fireViolet]
                color = color.mixed(with: tints[index % tints.count], amount: 0.20).lighter(0.10)
            } else if facet.slope > 0.8, random.unit() > 0.55, !spec.isMuted {
                let tint = c.x < 0 ? GemColor.fireWarm : GemColor.fireCool
                color = color.mixed(with: tint, amount: isRadiant ? 0.26 : 0.16)
            }

            let path = CGMutablePath()
            path.addLines(between: facet.points.map(map))
            path.closeSubpath()

            // Internal reflection gradient across each facet: brighter on
            // the edge facing the key light, deeper on the far edge.
            let mapped = facet.points.map(map)
            let lightDirection = CGPoint(x: light.x, y: -light.y)
            let sorted = mapped.sorted {
                ($0.x * lightDirection.x + $0.y * lightDirection.y)
                    > ($1.x * lightDirection.x + $1.y * lightDirection.y)
            }
            let gradientColors = [
                color.lighter(0.16).cgColor,
                color.cgColor,
                color.darker(0.18).cgColor
            ] as CFArray
            context.saveGState()
            context.addPath(path)
            context.clip()
            if let first = sorted.first, let last = sorted.last,
               let gradient = CGGradient(colorsSpace: space, colors: gradientColors, locations: [0, 0.5, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: first,
                    end: last,
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            } else {
                context.setFillColor(color.cgColor)
                context.fill(path.boundingBoxOfPath)
            }
            context.restoreGState()
        }

        // 3. Inner glow: light gathered in the table.
        let glowColor = palette.color(atAngle: .pi / 2).facet(
            brightness: 1, hueShift: 0, muted: spec.isMuted, glass: isGlass
        )
        let centerPoint = map(CGPoint(x: -0.04, y: 0.05))
        context.saveGState()
        context.setBlendMode(.screen)
        let glowColors = [
            glowColor.withAlpha(isRadiant ? 0.55 : 0.44).cgColor,
            glowColor.withAlpha(0.10).cgColor,
            glowColor.withAlpha(0).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: glowColors, locations: [0, 0.45, 1]) {
            context.drawRadialGradient(
                gradient,
                startCenter: centerPoint, startRadius: 0,
                endCenter: centerPoint, endRadius: radius * 0.78,
                options: []
            )
        }
        context.restoreGState()

        // 4. Rim. Cut stones keep pavilion depth (a darker girdle band);
        // geodesic crystals glow at the rim like backlit glass.
        let geometricCenter = map(.zero)
        let isGeodesic = spec.cut == .tumbled || spec.cut == .rough || isGlass || isHero
        if isGeodesic {
            context.saveGState()
            context.setBlendMode(.screen)
            let rimGlow = glowColor.lighter(0.25)
            let rimColors = [
                rimGlow.withAlpha(0).cgColor,
                rimGlow.withAlpha(spec.isMuted ? 0.14 : 0.30).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: rimColors, locations: [0, 1]) {
                context.drawRadialGradient(
                    gradient,
                    startCenter: geometricCenter, startRadius: radius * 0.58,
                    endCenter: geometricCenter, endRadius: radius * 1.0,
                    options: [.drawsAfterEndLocation]
                )
            }
            context.restoreGState()
        } else {
            let rimColors = [
                GemColor(red: 0.02, green: 0.02, blue: 0.08).withAlpha(0).cgColor,
                GemColor(red: 0.02, green: 0.02, blue: 0.08).withAlpha(0.22).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: rimColors, locations: [0, 1]) {
                context.drawRadialGradient(
                    gradient,
                    startCenter: geometricCenter, startRadius: radius * 0.66,
                    endCenter: geometricCenter, endRadius: radius * 1.02,
                    options: [.drawsAfterEndLocation]
                )
            }
        }

        // 5. Step cut table streaks and radiant core star.
        if spec.cut == .step {
            context.saveGState()
            context.setBlendMode(.screen)
            context.setStrokeColor(UIColor(white: 1, alpha: 0.20).cgColor)
            context.setLineWidth(max(1, radius * 0.07))
            for offset in [-0.16, 0.12] as [CGFloat] {
                context.move(to: map(CGPoint(x: -0.42 + offset, y: -0.10 + offset)))
                context.addLine(to: map(CGPoint(x: -0.02 + offset, y: 0.36 + offset)))
            }
            context.strokePath()
            context.restoreGState()
        }
        if isRadiant || spec.cut == .brilliant {
            let strength = isRadiant
                ? max(0.62, coreStarStrength)
                : 0.42
            drawCoreStar(
                context: context,
                center: map(.zero),
                radius: radius * (isHero ? 0.58 : (isRadiant ? 0.62 : 0.46)),
                rays: spec.symmetry,
                strength: strength
            )
        }

        // 6. Facet edges: hairline internal edges, brighter girdle.
        let edgeWidth = min(max(radius * 0.035, 0.45), 1.1)
        context.setLineJoin(.round)
        context.setStrokeColor(UIColor(white: 1, alpha: isGlass ? 0.30 : (spec.isMuted ? 0.14 : 0.24)).cgColor)
        context.setLineWidth(edgeWidth)
        for facet in facetList {
            let path = CGMutablePath()
            path.addLines(between: facet.points.map(map))
            path.closeSubpath()
            context.addPath(path)
        }
        context.strokePath()

        // Specular kiss inside the upper-left crown (rotates with the body,
        // complementing the screen-fixed key light sprite).
        context.saveGState()
        context.setBlendMode(.screen)
        let specCenter = map(CGPoint(x: -0.34, y: 0.42))
        let specColors = [
            UIColor(white: 1, alpha: isGlass ? 0.26 : 0.34).cgColor,
            UIColor(white: 1, alpha: 0).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: specColors, locations: [0, 1]) {
            context.translateBy(x: specCenter.x, y: specCenter.y)
            context.rotate(by: .pi / 4.5)
            context.scaleBy(x: 1.7, y: 0.62)
            context.drawRadialGradient(
                gradient,
                startCenter: .zero, startRadius: 0,
                endCenter: .zero, endRadius: radius * 0.26,
                options: []
            )
        }
        context.restoreGState()
        context.restoreGState() // outline clip

        // 7. Girdle outline and a brighter rim arc toward the key light.
        context.addPath(outlinePath)
        context.setStrokeColor(UIColor(white: 1, alpha: isGlass ? 0.55 : (spec.isMuted ? 0.36 : 0.62)).cgColor)
        context.setLineWidth(edgeWidth * 1.55)
        context.strokePath()
        if !spec.isMuted {
            context.saveGState()
            context.addPath(outlinePath)
            context.replacePathWithStrokedPath()
            context.clip()
            let rimLight = [
                UIColor(white: 1, alpha: 0.95).cgColor,
                UIColor(white: 1, alpha: 0).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: rimLight, locations: [0, 1]) {
                let start = map(CGPoint(x: -0.75, y: 0.75))
                context.drawRadialGradient(
                    gradient,
                    startCenter: start, startRadius: 0,
                    endCenter: start, endRadius: radius * 1.1,
                    options: []
                )
            }
            context.restoreGState()
        }

        // 8. Self-reported fairness ring (existing semantic marker).
        if spec.showsDashedRing {
            let ringRadius = radius * 0.80
            let dashCount = max(Constants.Jar.manualDashCount, 1)
            let dashLength = 2 * CGFloat.pi * ringRadius / CGFloat(dashCount * 2)
            let ringCenter = map(.zero)
            context.saveGState()
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.55).cgColor)
            context.setLineWidth(max(0.9, radius * 0.07))
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: [dashLength, dashLength])
            context.strokeEllipse(in: CGRect(
                x: ringCenter.x - ringRadius,
                y: ringCenter.y - ringRadius,
                width: ringRadius * 2,
                height: ringRadius * 2
            ))
            context.restoreGState()
        }

        // 8b. Pin-point lights where geodesic facets meet.
        if spec.cut == .tumbled, !spec.isMuted {
            var dotRandom = GemRandom(seed: UInt64(0xD07 + spec.variant * 31))
            let vertices = facetList.flatMap(\.points)
            var seen = Set<Int>()
            var placed = 0
            for point in vertices where placed < 5 {
                let key = Int((point.x * 1_000).rounded()) * 10_007 + Int((point.y * 1_000).rounded())
                guard !seen.contains(key), hypot(point.x, point.y) < 0.86 else { continue }
                seen.insert(key)
                guard dotRandom.unit() > 0.62 else { continue }
                placed += 1
                let center = map(point)
                let dot = max(0.7, radius * 0.045)
                context.saveGState()
                context.setBlendMode(.screen)
                let colors = [
                    UIColor(white: 1, alpha: 0.95).cgColor,
                    UIColor(white: 1, alpha: 0).cgColor
                ] as CFArray
                if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                    context.drawRadialGradient(
                        gradient,
                        startCenter: center, startRadius: 0,
                        endCenter: center, endRadius: dot * 2.2,
                        options: []
                    )
                }
                context.restoreGState()
            }
        }

        // 9. Baked micro sparkles on upper vertices.
        if spec.sparkleCount > 0 {
            // Upper-right and left vertices: the dynamic glint owns the
            // upper-left, so baked and live sparkles never pile up.
            let preferred: [CGFloat] = [0.95, -2.75, 1.75, -0.35, 2.6]
            var used = Set<Int>()
            for (rank, angle) in preferred.prefix(spec.sparkleCount).enumerated() {
                guard let entry = outlinePoints.enumerated()
                    .filter({ !used.contains($0.offset) })
                    .min(by: {
                        abs(remainder(atan2($0.element.y, $0.element.x) - angle, .pi * 2))
                            < abs(remainder(atan2($1.element.y, $1.element.x) - angle, .pi * 2))
                    })
                else { continue }
                used.insert(entry.offset)
                let point = map(CGPoint(x: entry.element.x * 0.95, y: entry.element.y * 0.95))
                drawSparkle(
                    context: context,
                    center: point,
                    length: radius * (rank == 0 ? 0.22 : 0.15) * (isRadiant ? 0.8 : 1),
                    alpha: rank == 0 ? 0.9 : 0.62
                )
            }
        }
    }

    private static func drawCoreStar(
        context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        rays: Int,
        strength: CGFloat
    ) {
        let space = CGColorSpaceCreateDeviceRGB()
        context.saveGState()
        context.setBlendMode(.screen)
        let count = max(6, rays)
        for index in 0 ..< count {
            let angle = CGFloat.pi / 2 + CGFloat(index) / CGFloat(count) * .pi * 2
            let tip = CGPoint(x: center.x + cos(angle) * radius, y: center.y - sin(angle) * radius)
            let side = CGFloat.pi / 2
            let width = radius * 0.07
            let path = CGMutablePath()
            path.move(to: CGPoint(
                x: center.x + cos(angle + side) * width,
                y: center.y - sin(angle + side) * width
            ))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(
                x: center.x + cos(angle - side) * width,
                y: center.y - sin(angle - side) * width
            ))
            path.closeSubpath()
            context.saveGState()
            context.addPath(path)
            context.clip()
            let colors = [
                UIColor(white: 1, alpha: 0.85 * strength).cgColor,
                UIColor(white: 1, alpha: 0).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: center, end: tip, options: [])
            }
            context.restoreGState()
        }
        let coreColors = [
            UIColor(white: 1, alpha: 0.95 * strength).cgColor,
            UIColor(white: 1, alpha: 0.30 * strength).cgColor,
            UIColor(white: 1, alpha: 0).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: coreColors, locations: [0, 0.35, 1]) {
            context.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: radius * 0.36,
                options: []
            )
        }
        context.restoreGState()
    }

    private static func drawSparkle(
        context: CGContext,
        center: CGPoint,
        length: CGFloat,
        alpha: CGFloat
    ) {
        context.saveGState()
        context.setBlendMode(.screen)
        context.setFillColor(UIColor(white: 1, alpha: alpha).cgColor)
        let waist = length * 0.16
        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x, y: center.y - length))
        path.addQuadCurve(to: CGPoint(x: center.x + length, y: center.y), control: CGPoint(x: center.x + waist, y: center.y - waist))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + length), control: CGPoint(x: center.x + waist, y: center.y + waist))
        path.addQuadCurve(to: CGPoint(x: center.x - length, y: center.y), control: CGPoint(x: center.x - waist, y: center.y + waist))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - length), control: CGPoint(x: center.x - waist, y: center.y - waist))
        path.closeSubpath()
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    // MARK: Palette

    private struct SectorPalette {
        /// Angle (radians, clockwise from 12 o'clock, 0...2π) → colour stops.
        let stops: [(angle: CGFloat, color: GemColor)]

        func color(atAngle mathAngle: CGFloat) -> GemColor {
            guard stops.count > 1 else { return stops.first?.color ?? GemColor(hex: "8A9BB8") }
            // Convert a y-up math angle to clockwise-from-top.
            var clockwise = CGFloat.pi / 2 - mathAngle
            clockwise = clockwise.truncatingRemainder(dividingBy: .pi * 2)
            if clockwise < 0 { clockwise += .pi * 2 }
            for index in stops.indices {
                let current = stops[index]
                let next = stops[(index + 1) % stops.count]
                let end = next.angle > current.angle ? next.angle : next.angle + .pi * 2
                var probe = clockwise
                if probe < current.angle { probe += .pi * 2 }
                if probe >= current.angle, probe <= end {
                    let span = max(end - current.angle, 0.0001)
                    let t = (probe - current.angle) / span
                    let smooth = t * t * (3 - 2 * t)
                    return current.color.mixed(with: next.color, amount: smooth)
                }
            }
            return stops[0].color
        }
    }

    private static func sectorPalette(
        spec: GemArtworkSpec,
        dispersionAnchor: GemColor?
    ) -> SectorPalette {
        if spec.cut == .glass {
            return SectorPalette(stops: [(0, GemColor(hex: "DCEBFF"))])
        }
        if let anchor = dispersionAnchor {
            // Clockwise from top: violet, magenta, rose, amber, peach, sky,
            // sapphire, indigo — the reference image's dispersion fan, each
            // stop pulled toward the effort colour so it stays personal.
            let fan = ["9A6BFF", "D65BD6", "FF5C7C", "FF8B45", "FFC59A", "7FD4FF", "4F86F0", "5A5FD8"]
            let stops = fan.enumerated().map { index, hex in
                (
                    angle: CGFloat(index) / CGFloat(fan.count) * .pi * 2,
                    color: GemColor(hex: hex).mixed(with: anchor, amount: 0.22)
                )
            }
            return SectorPalette(stops: stops)
        }
        let shares = spec.colors.filter { $0.fraction > 0 }
        guard shares.count > 1 else {
            return SectorPalette(stops: [(0, GemColor(hex: shares.first?.hex ?? "8A9BB8"))])
        }
        let total = shares.reduce(0) { $0 + $1.fraction }
        var cursor: CGFloat = 0
        var stops: [(angle: CGFloat, color: GemColor)] = []
        for share in shares {
            let span = CGFloat(share.fraction / max(total, 0.0001)) * .pi * 2
            if spec.cut == .radiant {
                // Radiant stones blend their colours around the girdle like
                // dispersion, instead of reading as a patchwork.
                stops.append((cursor + span * 0.5, GemColor(hex: share.hex)))
            } else {
                // Two stops per share keep each colour a flat arc with short
                // blended borders instead of one continuous rainbow.
                stops.append((cursor + span * 0.08, GemColor(hex: share.hex)))
                stops.append((cursor + span * 0.92, GemColor(hex: share.hex)))
            }
            cursor += span
        }
        return SectorPalette(stops: stops)
    }
}

// MARK: - Colour math

/// Minimal RGB value type so baking never allocates thousands of UIColors.
struct GemColor: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    static let fireWarm = GemColor(hex: "FFB38A")
    static let fireCool = GemColor(hex: "8FD6FF")
    static let fireViolet = GemColor(hex: "C8A6FF")

    init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard clean.count == 6, let value = UInt64(clean, radix: 16) else {
            self.init(red: 0.54, green: 0.60, blue: 0.72)
            return
        }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255
        )
    }

    var cgColor: CGColor { withAlpha(1).cgColor }

    func withAlpha(_ alpha: CGFloat) -> UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    func mixed(with other: GemColor, amount: CGFloat) -> GemColor {
        let t = min(max(amount, 0), 1)
        return GemColor(
            red: red + (other.red - red) * t,
            green: green + (other.green - green) * t,
            blue: blue + (other.blue - blue) * t
        )
    }

    func lighter(_ amount: CGFloat) -> GemColor {
        mixed(with: GemColor(red: 1, green: 1, blue: 1), amount: amount)
    }

    func darker(_ amount: CGFloat) -> GemColor {
        GemColor(red: red * (1 - amount), green: green * (1 - amount), blue: blue * (1 - amount))
    }

    var hsb: (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        var hue: CGFloat = 0
        if delta > 0.0001 {
            if maximum == red {
                hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maximum == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        let saturation = maximum <= 0 ? 0 : delta / maximum
        return (hue, saturation, maximum)
    }

    init(hue rawHue: CGFloat, saturation rawSaturation: CGFloat, brightness rawBrightness: CGFloat) {
        var hue = rawHue.truncatingRemainder(dividingBy: 1)
        if hue < 0 { hue += 1 }
        let saturation = min(max(rawSaturation, 0), 1)
        let brightness = min(max(rawBrightness, 0), 1)
        let sector = hue * 6
        let index = Int(sector) % 6
        let fraction = sector - floor(sector)
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch index {
        case 0: self.init(red: brightness, green: t, blue: p)
        case 1: self.init(red: q, green: brightness, blue: p)
        case 2: self.init(red: p, green: brightness, blue: t)
        case 3: self.init(red: p, green: q, blue: brightness)
        case 4: self.init(red: t, green: p, blue: brightness)
        default: self.init(red: brightness, green: p, blue: q)
        }
    }

    /// Vivid base used for every study gem (matches the historic floors).
    func vivid(muted: Bool) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        let value = hsb
        var saturation = max(value.saturation, value.saturation < 0.08 ? value.saturation : 0.72)
        let brightness = max(value.brightness, 0.90)
        if muted { saturation *= 0.62 }
        return (value.hue, saturation, brightness)
    }

    /// Deep → base → light ramp for one facet brightness in 0...1.
    func facet(brightness: CGFloat, hueShift: CGFloat, muted: Bool, glass: Bool) -> GemColor {
        if glass {
            let tone = 0.55 + brightness * 0.45
            return GemColor(red: tone * 0.90, green: tone * 0.95, blue: tone)
        }
        let base = vivid(muted: muted)
        let deep = GemColor(
            hue: base.hue - 0.018 + hueShift,
            saturation: min(1, base.saturation * 1.08 + 0.06),
            brightness: base.brightness * 0.46
        )
        let body = GemColor(
            hue: base.hue + hueShift,
            saturation: base.saturation,
            brightness: base.brightness
        )
        let light = GemColor(
            hue: base.hue + 0.022 + hueShift,
            saturation: base.saturation * 0.30,
            brightness: 1
        )
        if brightness < 0.58 {
            return deep.mixed(with: body, amount: brightness / 0.58)
        }
        return body.mixed(with: light, amount: (brightness - 0.58) / 0.42)
    }

    /// A darker, fully saturated body tone used under the facets.
    func shaded(_ brightness: CGFloat, muted: Bool, glass: Bool) -> GemColor {
        facet(brightness: brightness, hueShift: 0, muted: muted, glass: glass)
    }

    /// Additive halo colour: saturated and bright, never white.
    func haloColor(muted: Bool) -> UIColor {
        let base = vivid(muted: muted)
        return GemColor(
            hue: base.hue,
            saturation: min(1, base.saturation * 0.92 + 0.04),
            brightness: 1
        ).withAlpha(1)
    }
}

/// Deterministic xorshift so bakes are identical across launches and devices.
struct GemRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    mutating func unit() -> CGFloat {
        CGFloat(next() % 10_000) / 10_000
    }
}

extension UUID {
    /// Stable 64-bit FNV-1a hash of the UUID string, for presentation-only
    /// variety (facet variant, glint phase, twinkle order).
    var presentationHash: UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in uuidString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
