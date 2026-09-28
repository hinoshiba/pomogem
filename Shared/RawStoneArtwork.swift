import SwiftUI

/// The colourless raw stone (原石) of the data-free widget (D19,
/// Docs/GemExperienceDesign.md §8.7): the next gem, still uncut. It is the
/// same still picture for everyone — no theme colour, no weight, no count,
/// nothing read from the app — and it is drawn by code (no image asset).
///
/// A rough crystal seen from above and a little in front: an irregular
/// ten-sided girdle rising to a broken, tilted table of four points, cut
/// into sixteen uneven faces. It is not a regular solid (no die, no
/// medal). The widget never rolls, so the stone is lit once from the upper
/// left, like a stone on a desk under a lamp.
struct RawStoneGeometry: Equatable, Sendable {
    struct Facet: Equatable, Sendable {
        /// Three corners in unit space: centre (0, 0), y up, radius ≤ 1.
        let points: [CGPoint]
        /// Diffuse light on the face, 0 (dark) … 1 (facing the lamp).
        let shade: CGFloat
        /// Which way the face turns in the picture (unit x, y of its normal),
        /// for the warm upper-left and cool lower-right rims.
        let tilt: CGPoint
    }

    /// The faces; together they tile the silhouette exactly.
    let facets: [Facet]
    /// The girdle (silhouette), clockwise in y-up space from the top.
    let outline: [CGPoint]
    /// Where the lamp catches the table's upper-left corner (the star).
    let sparkle: CGPoint
    /// A second, smaller star on the girdle's upper right.
    let secondarySparkle: CGPoint

    /// Light from the upper left and in front (y up, toward the viewer +z).
    private static let lightDirection = normalized((x: -0.45, y: 0.55, z: 0.70))

    static let standard = RawStoneGeometry()

    init() {
        // The girdle: ten corners at uneven angles and distances (fixed,
        // not random), clockwise from the top left.
        let girdle: [(degrees: Double, radius: Double, height: Double)] = [
            (100, 0.97, 0.22), (62, 0.90, 0.30), (28, 0.98, 0.20), (-8, 0.93, 0.26),
            (-44, 0.96, 0.18), (-80, 0.88, 0.28), (-118, 0.97, 0.16), (-152, 0.92, 0.24),
            (170, 0.98, 0.20), (134, 0.90, 0.30)
        ]
        let rim: [Vector] = girdle.map { corner in
            let angle = corner.degrees * .pi / 180
            return (x: cos(angle) * corner.radius, y: sin(angle) * corner.radius, z: corner.height)
        }
        // The broken table: four raised points, each a little higher or
        // lower, so its two halves catch the lamp differently.
        let table: [Vector] = [
            (x: -0.22, y: 0.30, z: 0.98),
            (x: 0.24, y: 0.16, z: 0.90),
            (x: 0.08, y: -0.32, z: 0.84),
            (x: -0.34, y: -0.14, z: 0.92)
        ]
        // Faces as (point, point, point): 0…9 the girdle, 10…13 the table.
        let faces: [(Int, Int, Int)] = [
            // Around the upper-left table point.
            (10, 8, 9), (10, 9, 0), (10, 0, 1),
            // Upper right.
            (11, 1, 2), (11, 2, 3), (11, 3, 4),
            // Bottom.
            (12, 4, 5), (12, 5, 6),
            // Lower left.
            (13, 6, 7), (13, 7, 8),
            // Between the table points.
            (10, 1, 11), (11, 4, 12), (12, 6, 13), (13, 8, 10),
            // The table.
            (10, 11, 12), (10, 12, 13)
        ]
        let points = rim + table
        facets = faces.map { face in
            let a = points[face.0]
            let b = points[face.1]
            let c = points[face.2]
            var normal = Self.normalized(Self.cross(Self.minus(b, a), Self.minus(c, a)))
            if normal.z < 0 { normal = (x: -normal.x, y: -normal.y, z: -normal.z) }
            let diffuse = max(0, Self.dot(normal, Self.lightDirection))
            return Facet(
                points: [a, b, c].map { CGPoint(x: $0.x, y: $0.y) },
                shade: CGFloat(min(1, max(0, 0.08 + 0.92 * diffuse * diffuse))),
                tilt: CGPoint(x: normal.x, y: normal.y)
            )
        }
        outline = rim.map { CGPoint(x: $0.x, y: $0.y) }
        sparkle = CGPoint(x: table[0].x, y: table[0].y)
        secondarySparkle = CGPoint(x: rim[2].x, y: rim[2].y)
    }

    // MARK: Small vector helpers

    private typealias Vector = (x: Double, y: Double, z: Double)

    private static func rotate(_ p: Vector, x ax: Double, y ay: Double, z az: Double) -> Vector {
        var v = p
        v = (x: v.x, y: v.y * cos(ax) - v.z * sin(ax), z: v.y * sin(ax) + v.z * cos(ax))
        v = (x: v.x * cos(ay) + v.z * sin(ay), y: v.y, z: -v.x * sin(ay) + v.z * cos(ay))
        v = (x: v.x * cos(az) - v.y * sin(az), y: v.x * sin(az) + v.y * cos(az), z: v.z)
        return v
    }

    private static func minus(_ a: Vector, _ b: Vector) -> Vector { (a.x - b.x, a.y - b.y, a.z - b.z) }
    private static func dot(_ a: Vector, _ b: Vector) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private static func cross(_ a: Vector, _ b: Vector) -> Vector {
        (a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    private static func normalized(_ v: Vector) -> Vector {
        let length = max(dot(v, v).squareRoot(), 0.000_001)
        return (v.x / length, v.y / length, v.z / length)
    }

    /// Monotone chain, clockwise in y-up space.
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let unique: Set<SIMD2<Double>> = Set(points.map { SIMD2<Double>(Double($0.x), Double($0.y)) })
        let sorted: [SIMD2<Double>] = unique.sorted { lhs, rhs in
            lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x
        }
        guard sorted.count > 2 else { return sorted.map { CGPoint(x: $0.x, y: $0.y) } }
        func turn(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = []
        for point in sorted {
            while lower.count >= 2, turn(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        var upper: [SIMD2<Double>] = []
        for point in sorted.reversed() {
            while upper.count >= 2, turn(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        let counterClockwise = lower.dropLast() + upper.dropLast()
        return counterClockwise.reversed().map { CGPoint(x: $0.x, y: $0.y) }
    }

    /// Area of a polygon (shoelace), in unit space.
    static func area(_ polygon: [CGPoint]) -> CGFloat {
        guard polygon.count > 2 else { return 0 }
        var sum: CGFloat = 0
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }
}

/// The raw stone drawn in SwiftUI (`Canvas`; no UIKit, SpriteKit or asset),
/// so the widget extension and the app draw the same picture. With
/// `showsPlate`, it sits on an opaque deep-navy plate so a light or colourful
/// wallpaper never muddies it; a tinted widget omits the plate and the
/// floor shadow (a tint would turn the shadow into a pale disc) and keeps
/// the stone's facets as light and shade.
struct RawStoneArtwork: View {
    var showsPlate = false
    var showsShadow = true

    /// Deep navy of the plate (the widget's night palette).
    static let plateTop = Color(red: 20 / 255, green: 25 / 255, blue: 39 / 255)
    static let plateBottom = Color(red: 27 / 255, green: 33 / 255, blue: 54 / 255)
    /// Ice white: the stone has no theme colour yet.
    static let ice = Color(red: 0.88, green: 0.94, blue: 1.0)
    /// The jar's warm key-light rim (#FFB38A) and cool bounce (#8ACBFF).
    static let warmRim = Color(red: 1.0, green: 0.70, blue: 0.54)
    static let coolRim = Color(red: 0.54, green: 0.80, blue: 1.0)

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            if showsPlate {
                let plate = Path(roundedRect: bounds, cornerRadius: min(size.width, size.height) * 0.16, style: .continuous)
                context.fill(plate, with: .linearGradient(
                    Gradient(colors: [Self.plateTop, Self.plateBottom]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: size.width, y: size.height)
                ))
                context.stroke(plate, with: .color(Color(red: 170 / 255, green: 195 / 255, blue: 240 / 255).opacity(0.35)), lineWidth: 1)
            }
            Self.drawStone(in: &context, rect: bounds.insetBy(dx: size.width * 0.07, dy: size.height * 0.07), showsShadow: showsShadow)
        }
        .accessibilityHidden(true)
    }

    /// Draws the stone centred in `rect` (its radius is 0.44 of the shorter
    /// side, leaving room for the floor shadow and the halo).
    static func drawStone(in context: inout GraphicsContext, rect: CGRect, showsShadow: Bool = true) {
        let geometry = RawStoneGeometry.standard
        let radius = min(rect.width, rect.height) * 0.44
        let center = CGPoint(x: rect.midX, y: rect.midY - radius * 0.06)
        func point(_ unit: CGPoint) -> CGPoint {
            CGPoint(x: center.x + unit.x * radius, y: center.y - unit.y * radius)
        }
        func path(_ polygon: [CGPoint]) -> Path {
            var path = Path()
            guard let first = polygon.first else { return path }
            path.move(to: point(first))
            for corner in polygon.dropFirst() { path.addLine(to: point(corner)) }
            path.closeSubpath()
            return path
        }

        // Soft light around the stone and its shadow on the floor.
        let haloRadius = radius * 1.55
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - haloRadius, y: center.y - haloRadius, width: haloRadius * 2, height: haloRadius * 2)),
            with: .radialGradient(
                Gradient(colors: [ice.opacity(0.22), ice.opacity(0.07), .clear]),
                center: center,
                startRadius: radius * 0.4,
                endRadius: haloRadius
            )
        )
        let shadow = CGRect(x: center.x - radius * 0.78, y: center.y + radius * 0.86, width: radius * 1.56, height: radius * 0.30)
        if showsShadow {
            context.fill(
                Path(ellipseIn: shadow),
                with: .radialGradient(
                    Gradient(colors: [Color.black.opacity(0.42), .clear]),
                    center: CGPoint(x: shadow.midX, y: shadow.midY),
                    startRadius: 0,
                    endRadius: shadow.width / 2
                )
            )
        }

        // Faces: ice white, more opaque where the lamp reaches. Faces that
        // turn up-left take a faint warm rim, down-right a faint cool
        // bounce (the jar's light rig, §7.3) — still colourless overall.
        for facet in geometry.facets {
            let face = path(facet.points)
            context.fill(face, with: .color(ice.opacity(0.05 + 0.80 * facet.shade)))
            let warmth = max(0, -facet.tilt.x * 0.7 + facet.tilt.y * 0.7)
            let coolness = max(0, facet.tilt.x * 0.7 - facet.tilt.y * 0.7)
            if warmth > 0.05 {
                context.fill(face, with: .color(warmRim.opacity(0.22 * warmth)))
            }
            if coolness > 0.05 {
                context.fill(face, with: .color(coolRim.opacity(0.30 * coolness)))
            }
            context.stroke(
                face,
                with: .color(Color.white.opacity(0.10 + 0.32 * facet.shade)),
                style: StrokeStyle(lineWidth: max(0.4, radius * 0.010), lineJoin: .round)
            )
        }
        // Light from within, then the girdle's bright rim.
        context.fill(
            path(geometry.outline),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.34), Color.white.opacity(0.08), Color.white.opacity(0)]),
                center: point(CGPoint(x: -0.12, y: 0.10)),
                startRadius: 0,
                endRadius: radius * 0.85
            )
        )
        context.stroke(
            path(geometry.outline),
            with: .color(Color.white.opacity(0.85)),
            style: StrokeStyle(lineWidth: max(0.8, radius * 0.026), lineJoin: .round)
        )

        // Two still stars where the lamp catches a corner (no twinkle).
        drawStar(in: &context, at: point(geometry.sparkle), arm: radius * 0.34, thickness: radius * 0.036)
        drawStar(in: &context, at: point(geometry.secondarySparkle), arm: radius * 0.16, thickness: radius * 0.024)
    }

    /// A four-point star: a longer horizontal arm, a round white core.
    private static func drawStar(in context: inout GraphicsContext, at center: CGPoint, arm: CGFloat, thickness: CGFloat) {
        for vertical in [false, true] {
            let length = vertical ? arm : arm * 1.4
            let rect = vertical
                ? CGRect(x: center.x - thickness / 2, y: center.y - length, width: thickness, height: length * 2)
                : CGRect(x: center.x - length, y: center.y - thickness / 2, width: length * 2, height: thickness)
            context.fill(
                Path(ellipseIn: rect),
                with: .radialGradient(
                    Gradient(colors: [Color.white.opacity(0.95), Color.white.opacity(0)]),
                    center: center,
                    startRadius: 0,
                    endRadius: length
                )
            )
        }
        let core = thickness * 1.4
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2)),
            with: .color(Color.white.opacity(0.95))
        )
    }
}
