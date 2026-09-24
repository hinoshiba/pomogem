import SpriteKit
import UIKit

/// Visual cut used to draw one study gem. The cut is presentation only: it
/// never changes the circular physics body, the mass-derived radius, or any
/// persisted value. `GemCutLadder` is the single table that maps recorded
/// effort to a cut.
enum GemCut: String, CaseIterable, Sendable {
    /// Loose measured gem (and an aggregate below 2.5 kg): a many-faceted
    /// geodesic crystal.
    case tumbled
    /// Self-reported gem: the plain icosahedron, lower contrast. Its dashed
    /// ring keeps the measured/self-reported distinction readable.
    case rough
    /// Zero-mass tutorial gem: colourless glass.
    case glass
    /// 2.5–25 kg aggregate (and the achievement setting): octagonal step cut.
    case step
    /// 25–250 kg aggregate: round brilliant (table, star, kite, girdle).
    case brilliant
    /// 250 kg and above: radiant brilliant with a white heart.
    case radiant
    /// The lifetime "time core": a decagonal brilliant drawn in SwiftUI.
    case hero
}

/// Light budget for one rung. Every value is deterministic; brilliance grows
/// only with recorded grams, never with chance, completion count or payment.
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
    /// Tiny static sparkles baked into the facet texture (rotationally
    /// symmetric, so a rolling gem never looks lit from one side).
    var sparkleCount: Int
    /// 0...1 strength of the per-facet light/dark scintillation pattern.
    var facetContrast: CGFloat
    /// A3 and above: a white heart in the table.
    var hasWhiteCore = false
    /// A4: a ring of crown sparkles around the table.
    var hasCrown = false
    /// Achievement setting: four copper prongs.
    var hasProngs = false
}

/// The single table that maps recorded effort to cuts.
///
/// Aggregates are ranked by the grams they contain (A0…A4), never by their
/// decimal level or pebble count: ten one-minute completions (100 g) stay at
/// the loose-gem rung, so splitting time cannot buy a brighter crystal.
struct GemCutLadder: Sendable {
    var loose: GemCutRung
    var selfReported: GemCutRung
    var tutorial: GemCutRung
    var achievement: GemCutRung
    /// A0 … A4, indexed by `aggregateTier(grams:)`.
    var aggregates: [GemCutRung]

    static let standard = GemCutLadder(
        loose: GemCutRung(
            cut: .tumbled, symmetry: 12, haloScale: 2.2, haloAlpha: 0.50,
            glintCount: 1, glintScale: 0.9, sparkleCount: 2, facetContrast: 0.85
        ),
        selfReported: GemCutRung(
            cut: .rough, symmetry: 12, haloScale: 1.9, haloAlpha: 0.20,
            glintCount: 0, glintScale: 0, sparkleCount: 0, facetContrast: 0.40
        ),
        tutorial: GemCutRung(
            cut: .glass, symmetry: 12, haloScale: 1.8, haloAlpha: 0.08,
            glintCount: 0, glintScale: 0, sparkleCount: 1, facetContrast: 0.35
        ),
        achievement: GemCutRung(
            cut: .step, symmetry: 8, haloScale: 2.3, haloAlpha: 0.55,
            glintCount: 1, glintScale: 0.9, sparkleCount: 1, facetContrast: 0.80,
            hasProngs: true
        ),
        aggregates: [
            // A0 (< 2.5 kg): the same rung as a loose gem, plus its
            // composition fan.
            GemCutRung(
                cut: .tumbled, symmetry: 12, haloScale: 2.3, haloAlpha: 0.55,
                glintCount: 1, glintScale: 0.9, sparkleCount: 2, facetContrast: 0.85
            ),
            // A1 (2.5–25 kg)
            GemCutRung(
                cut: .step, symmetry: 8, haloScale: 2.4, haloAlpha: 0.60,
                glintCount: 1, glintScale: 0.95, sparkleCount: 2, facetContrast: 0.75
            ),
            // A2 (25–250 kg)
            GemCutRung(
                cut: .brilliant, symmetry: 8, haloScale: 2.5, haloAlpha: 0.68,
                glintCount: 2, glintScale: 1.1, sparkleCount: 3, facetContrast: 0.95
            ),
            // A3 (250 kg–2.5 t)
            GemCutRung(
                cut: .radiant, symmetry: 10, haloScale: 2.6, haloAlpha: 0.74,
                glintCount: 3, glintScale: 1.1, sparkleCount: 4, facetContrast: 1,
                hasWhiteCore: true
            ),
            // A4 (≥ 2.5 t)
            GemCutRung(
                cut: .radiant, symmetry: 12, haloScale: 2.7, haloAlpha: 0.80,
                glintCount: 3, glintScale: 1.1, sparkleCount: 5, facetContrast: 1,
                hasWhiteCore: true, hasCrown: true
            )
        ]
    )

    /// A1 starts at one standard ×10 of 25-minute completions (2.5 kg).
    static let firstCrystalTierGrams = Constants.Mass.measuredPebbleGrams
        * Constants.Jar.aggregateFanIn

    /// 0 = A0 (< 2.5 kg), 1 = A1 (< 25 kg), 2 = A2 (< 250 kg),
    /// 3 = A3 (< 2.5 t), 4 = A4.
    static func aggregateTier(grams rawGrams: Int) -> Int {
        let grams = max(0, rawGrams)
        var threshold = firstCrystalTierGrams
        var tier = 0
        while tier < 4, grams >= threshold {
            tier += 1
            threshold = threshold.multipliedReportingOverflow(by: 10).partialValue
        }
        return tier
    }

    func rung(aggregateGrams grams: Int) -> GemCutRung {
        guard !aggregates.isEmpty else { return loose }
        return aggregates[min(Self.aggregateTier(grams: grams), aggregates.count - 1)]
    }

    func rung(for descriptor: PebbleDescriptor) -> GemCutRung {
        if descriptor.aggregate != nil { return rung(aggregateGrams: descriptor.grams) }
        if descriptor.isAchievement { return achievement }
        if descriptor.isTutorial { return tutorial }
        return descriptor.isMeasured ? loose : selfReported
    }

    /// s(g) = clamp(√(g ÷ 250 g), 0.6, 1.0). A loose halo tops out at 25
    /// minutes; its size already grows with mass.
    static func looseHaloStrength(grams: Int) -> CGFloat {
        let nominal = CGFloat(max(1, Constants.Mass.measuredPebbleGrams))
        let ratio = CGFloat(max(0, grams)) / nominal
        return min(1, max(0.6, ratio.squareRoot()))
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
    var hasWhiteCore = false
    var hasCrown = false
    var hasProngs = false
    /// Increase Contrast: brighter facet edges (+0.2 alpha).
    var edgeBoost: CGFloat = 0

    static let variantCount = 4

    init(
        cut: GemCut,
        symmetry: Int,
        colors: [GemColorShare],
        variant: Int,
        facetContrast: CGFloat,
        sparkleCount: Int,
        isMuted: Bool,
        showsDashedRing: Bool,
        hasWhiteCore: Bool = false,
        hasCrown: Bool = false,
        hasProngs: Bool = false,
        edgeBoost: CGFloat = 0
    ) {
        self.cut = cut
        self.symmetry = symmetry
        self.colors = colors
        self.variant = variant
        self.facetContrast = facetContrast
        self.sparkleCount = sparkleCount
        self.isMuted = isMuted
        self.showsDashedRing = showsDashedRing
        self.hasWhiteCore = hasWhiteCore
        self.hasCrown = hasCrown
        self.hasProngs = hasProngs
        self.edgeBoost = edgeBoost
    }

    /// The one place that turns a rung plus colours into a bake spec, used
    /// by the jar and by every share-card gem so both show the same stone.
    init(
        rung: GemCutRung,
        colors: [GemColorShare],
        variant: Int,
        isMuted: Bool,
        showsDashedRing: Bool,
        edgeBoost: CGFloat = 0
    ) {
        self.init(
            cut: rung.cut,
            symmetry: rung.symmetry,
            colors: colors,
            variant: variant,
            facetContrast: rung.facetContrast,
            sparkleCount: rung.sparkleCount,
            isMuted: isMuted,
            showsDashedRing: showsDashedRing,
            hasWhiteCore: rung.hasWhiteCore,
            hasCrown: rung.hasCrown,
            hasProngs: rung.hasProngs,
            edgeBoost: edgeBoost
        )
    }

    /// The same bake spec with another of the four variants.
    func withVariant(_ variant: Int) -> GemArtworkSpec {
        GemArtworkSpec(
            cut: cut,
            symmetry: symmetry,
            colors: colors,
            variant: variant,
            facetContrast: facetContrast,
            sparkleCount: sparkleCount,
            isMuted: isMuted,
            showsDashedRing: showsDashedRing,
            hasWhiteCore: hasWhiteCore,
            hasCrown: hasCrown,
            hasProngs: hasProngs,
            edgeBoost: edgeBoost
        )
    }

    /// Value-free individuality: one of four same-rung variants from the
    /// session UUID (never a rarity, never a ranking).
    static func variant(for id: UUID) -> Int {
        Int(id.presentationHash % UInt64(variantCount))
    }

    /// Up to four colour shares, largest first.
    static func aggregateColors(
        _ mix: [StratumColorFraction],
        fallbackHex: String
    ) -> [GemColorShare] {
        let sorted = mix
            .filter { $0.fraction > 0 }
            .sorted { $0.fraction == $1.fraction ? $0.hex < $1.hex : $0.fraction > $1.fraction }
            .prefix(4)
        guard !sorted.isEmpty else { return [GemColorShare(hex: fallbackHex, fraction: 1)] }
        return sorted.map { GemColorShare(hex: $0.hex, fraction: $0.fraction) }
    }

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
            showsDashedRing ? "d" : "-",
            hasWhiteCore ? "w" : "-",
            hasCrown ? "k" : "-",
            hasProngs ? "p" : "-",
            "e\(Int((edgeBoost * 10).rounded()))"
        ].joined(separator: "|")
    }
}

/// Core Graphics renderer for faceted gems. All textures are baked once per
/// (spec, size bucket, screen scale) and cached; nothing here runs per frame.
///
/// Lighting is split in two (see Docs/GemExperienceDesign.md §7.3):
/// the baked body carries only light that does not depend on direction
/// (view-direction shading, Fresnel rim, inner glow, rotationally symmetric
/// sparkles), because the body rotates with physics. Every directional light
/// (key sheen, pavilion shade, bounce and rim) lives in the screen-fixed
/// `gem.lightRig` sprites in `PebbleNode`.
enum GemArtwork {
    /// Every cut's silhouette is scaled to the same share of its physics
    /// circle, so visible area stays proportional to mass across cuts and
    /// variants.
    static let silhouetteAreaRatio: CGFloat = 0.93
    /// The silhouette may overhang the circular physics body by at most 2 %.
    static let silhouetteMaximumRadius: CGFloat = 1.02

    // MARK: Public entry points

    /// Unit-space (radius 1, y up) outline shared by the texture and the
    /// container path, so both always agree exactly.
    static func outline(cut: GemCut, symmetry: Int, variant: Int) -> [CGPoint] {
        layout(cut: cut, symmetry: symmetry, variant: variant).outer
    }

    /// Facet count of a cut, for tests and documentation.
    static func facetCount(cut: GemCut, symmetry: Int, variant: Int) -> Int {
        layout(cut: cut, symmetry: symmetry, variant: variant).facets.count
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

    /// Texture size in points for a gem of `radius`, including the outline
    /// stroke margin. The sprite must use this size.
    static func bodySpriteSize(radius: CGFloat) -> CGSize {
        let side = (radius + margin(radius: radius)) * 2
        return CGSize(width: side, height: side)
    }

    /// Name of a jar body texture in `GemTextureAtlas`: one per (spec, size
    /// bucket, display scale). `scale` is the display scale of the view that
    /// shows it (the SKView's `contentScaleFactor` or SwiftUI's
    /// `displayScale`).
    static func bodyTextureName(for spec: GemArtworkSpec, radius: CGFloat, scale rawScale: CGFloat) -> String {
        "gem.body|\(spec.cacheKey)|r\(sizeBucket(radius: radius))|x\(renderScale(rawScale))"
    }

    /// Uncached bake of a jar body (the atlas keeps the result). Thread-safe:
    /// Core Graphics only, so it may run off the main thread.
    static func renderBodyImage(for spec: GemArtworkSpec, radius: CGFloat, scale rawScale: CGFloat) -> UIImage {
        renderBody(spec: spec, radius: sizeBucket(radius: radius), scale: renderScale(rawScale))
    }

    /// The body texture a jar sprite shows (atlas-backed once packed).
    @MainActor
    static func bodyTexture(for spec: GemArtworkSpec, radius: CGFloat, scale: CGFloat) -> SKTexture {
        GemTextureAtlas.shared.texture(named: bodyTextureName(for: spec, radius: radius, scale: scale)) {
            renderBodyImage(for: spec, radius: radius, scale: scale)
        }
    }

    /// The same renderer as a SwiftUI/UIKit image (share cards, overview).
    static func bodyImage(for spec: GemArtworkSpec, radius: CGFloat, scale rawScale: CGFloat) -> UIImage {
        let bucket = sizeBucket(radius: radius)
        let scale = renderScale(rawScale)
        let key = NSString(string: "\(spec.cacheKey)|r\(bucket)|x\(scale)")
        if let cached = imageCache.object(forKey: key) { return cached }
        let image = renderBody(spec: spec, radius: bucket, scale: scale)
        imageCache.setObject(image, forKey: key, cost: byteCost(image))
        return image
    }

    // MARK: Time core

    /// Every core is baked once at this diameter and scaled down by SwiftUI,
    /// so an animated frame change never re-renders on the main thread.
    static let coreBakeDiameter: CGFloat = 192

    /// Top five theme shares plus "other", quantised to 5 % (20 girdle
    /// slots). The order is stable: largest first, ties by hex.
    static func quantizedCoreShares(_ raw: [GemColorShare]) -> [GemColorShare] {
        let valid = raw.filter { $0.fraction > 0 }
        guard !valid.isEmpty else { return [GemColorShare(hex: Constants.Color.textMute, fraction: 1)] }
        let total: Double = valid.reduce(0) { $0 + $1.fraction }
        let normalized: [GemColorShare] = valid.map { share in
            GemColorShare(hex: share.hex.uppercased(), fraction: share.fraction / total)
        }
        let sorted: [GemColorShare] = normalized.sorted { lhs, rhs in
            if lhs.fraction == rhs.fraction { return lhs.hex < rhs.hex }
            return lhs.fraction > rhs.fraction
        }
        var entries = Array(sorted.prefix(5))
        let rest = sorted.dropFirst(5)
        if !rest.isEmpty {
            let restTotal = rest.reduce(0) { $0 + $1.fraction }
            var mixed = GemColor(hex: rest.first?.hex ?? Constants.Color.textMute)
            var accumulated = rest.first?.fraction ?? 0
            for share in rest.dropFirst() {
                accumulated += share.fraction
                mixed = mixed.mixed(with: GemColor(hex: share.hex), amount: CGFloat(share.fraction / accumulated))
            }
            entries.append(GemColorShare(hex: mixed.hexString, fraction: restTotal))
        }
        // Largest-remainder rounding to 20 slots.
        let slots = 20
        var counts = entries.map { Int(($0.fraction * Double(slots)).rounded(.down)) }
        var remaining = slots - counts.reduce(0, +)
        let order = entries.indices.sorted {
            let a = entries[$0].fraction * Double(slots) - Double(counts[$0])
            let b = entries[$1].fraction * Double(slots) - Double(counts[$1])
            return a == b ? $0 < $1 : a > b
        }
        var cursor = 0
        while remaining > 0, !order.isEmpty {
            counts[order[cursor % order.count]] += 1
            remaining -= 1
            cursor += 1
        }
        if counts.first == 0 { counts[0] = 1 }
        var result: [GemColorShare] = []
        for (entry, count) in zip(entries, counts) where count > 0 {
            result.append(GemColorShare(hex: entry.hex, fraction: Double(count) / Double(slots)))
        }
        return result
    }

    /// Halo tint of the core: the share-weighted colour with 30 % aurora
    /// violet, so the bloom belongs to the scene rather than one theme.
    static func coreHaloColor(shares: [GemColorShare]) -> UIColor {
        let quantized = quantizedCoreShares(shares)
        var mixed = GemColor(hex: quantized.first?.hex ?? Constants.Color.textMute)
        var accumulated = quantized.first?.fraction ?? 1
        for share in quantized.dropFirst() {
            accumulated += share.fraction
            mixed = mixed.mixed(with: GemColor(hex: share.hex), amount: CGFloat(share.fraction / accumulated))
        }
        let tone = GemTone(hex: mixed.hexString, muted: false, glass: false)
        return tone.halo.mixed(with: GemColor(hex: Constants.Color.auroraViolet), amount: 0.30).withAlpha(1)
    }

    /// Pale bloom that hugs the core's girdle: the halo tint lifted toward
    /// white, so the edge glows like the reference without a neon ring.
    static func coreRimGlowColor(shares: [GemColorShare]) -> UIColor {
        GemColor(coreHaloColor(shares: shares)).mixed(with: .white, amount: 0.74).withAlpha(1)
    }

    /// Time core: a luminous radial brilliant whose twenty facets are
    /// painted by the approximate theme shares. Deterministic for (shares,
    /// level, scale).
    static func coreImage(shares: [GemColorShare], level: Int, scale rawScale: CGFloat) -> UIImage {
        let quantized = quantizedCoreShares(shares)
        let clampedLevel = min(max(level, 1), 6)
        let scale = renderScale(rawScale)
        let palette = quantized
            .map { "\($0.hex)@\(Int(($0.fraction * 20).rounded()))" }
            .joined(separator: ",")
        let key = NSString(string: "core3|\(palette)|L\(clampedLevel)|x\(scale)")
        if let cached = imageCache.object(forKey: key) { return cached }
        let image = renderHero(shares: quantized, level: clampedLevel, litVesselFacets: nil, scale: scale)
        imageCache.setObject(image, forKey: key, cost: byteCost(image))
        return image
    }

    /// The core gains a crown of lights at the 2.5 t stage (level 4).
    static func coreHasCrown(level: Int) -> Bool { level >= 4 }

    /// Single-colour convenience (legacy callers and the fusion card).
    static func coreImage(colorHex: String, level: Int, scale: CGFloat) -> UIImage {
        coreImage(shares: [GemColorShare(hex: colorHex, fraction: 1)], level: level, scale: scale)
    }

    /// Before the first 2.5 kg: a colourless vessel whose ten upper facets
    /// light up one per 250 g. No colour enters until the core is born.
    static func vesselImage(litFacets: Int, scale rawScale: CGFloat) -> UIImage {
        let lit = min(max(litFacets, 0), 10)
        let scale = renderScale(rawScale)
        let key = NSString(string: "vessel3|\(lit)|x\(scale)")
        if let cached = imageCache.object(forKey: key) { return cached }
        let image = renderHero(
            shares: [GemColorShare(hex: "#DCEBFF", fraction: 1)],
            level: 0,
            litVesselFacets: lit,
            scale: scale
        )
        imageCache.setObject(image, forKey: key, cost: byteCost(image))
        return image
    }

    // MARK: Gem bed (積み上がりの光)

    /// The lifetime gem bed behind the physics bodies, baked into one
    /// texture per height (Docs/EngagementArchitecture.md §3.2 いまの瓶).
    /// Small faceted chips in the colours of the lifetime share fan, dimmer
    /// and smaller than any real gem, with a few static sparkles and a soft
    /// top edge. Chip positions depend only on (row, column), never on the
    /// height, so a taller bucket only adds chips on top: the bed never
    /// rearranges or dims as it grows.
    static func bedTexture(
        width rawWidth: CGFloat,
        height rawHeight: CGFloat,
        slotHexes: [String],
        scale rawScale: CGFloat
    ) -> SKTexture {
        let width = max(8, rawWidth.rounded())
        let height = max(2, rawHeight.rounded())
        let scale = renderScale(rawScale)
        let key = NSString(string: "bed|w\(Int(width))|h\(Int(height))|\(slotHexes.joined(separator: ","))|x\(scale)")
        if let cached = bodyCache.object(forKey: key) { return cached }
        let image = bedImage(width: width, height: height, slotHexes: slotHexes, scale: scale)
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        bodyCache.setObject(texture, forKey: key, cost: byteCost(image))
        return texture
    }

    /// Chip pitch of the bed (points). Chips are 4.5–8.5 pt across, well
    /// below the smallest real gem (about 20 pt), so they read as ground,
    /// not as something to tap.
    static let bedRowPitch: CGFloat = 4.8
    static let bedColumnPitch: CGFloat = 7.2

    fileprivate struct BedChip {
        var center: CGPoint
        var size: CGFloat
        var rotation: CGFloat
        var radii: [CGFloat]
        var slot: Int
        var shade: CGFloat
        var sparkle: Bool
    }

    /// Top edge of the bed at `x` for a bed `height` tall: a calm, uneven
    /// line (88–100 % of the height), never a heap.
    static func bedProfile(x: CGFloat, width: CGFloat, height: CGFloat) -> CGFloat {
        let u = x / max(width, 1)
        let wave = 0.5 + 0.30 * sin(u * .pi * 2 * 1.35 + 0.8) + 0.20 * sin(x * 0.19 + 1.7)
        return height * (0.88 + 0.12 * min(max(wave, 0), 1))
    }

    fileprivate static func bedChips(width: CGFloat, height: CGFloat) -> [BedChip] {
        var chips: [BedChip] = []
        let rows = Int((height / bedRowPitch).rounded(.up)) + 1
        for row in 0 ..< rows {
            let stagger: CGFloat = row.isMultiple(of: 2) ? 0 : 0.5
            var column = 0
            var x = (stagger - 0.5) * bedColumnPitch
            while x < width + bedColumnPitch * 0.5 {
                var random = GemRandom(seed: UInt64(row) &* 7_919 &+ UInt64(column) &* 104_729 &+ 11)
                // Mostly 5–9.5 pt, one in seven a larger 9.5–12.5 pt crystal.
                let size = random.next() % 7 == 0 ? 9.5 + random.unit() * 3 : 5 + random.unit() * 4.5
                let sides = 4 + Int(random.next() % 3)
                chips.append(BedChip(
                    center: CGPoint(
                        x: x + (random.unit() - 0.5) * bedColumnPitch * 0.6,
                        y: CGFloat(row) * bedRowPitch + (random.unit() - 0.5) * bedRowPitch * 0.8
                    ),
                    size: size,
                    rotation: random.unit() * .pi * 2,
                    radii: (0 ..< sides).map { _ in 0.72 + random.unit() * 0.28 },
                    slot: Int(random.next() % 20),
                    shade: 0.82 + random.unit() * 0.30,
                    sparkle: random.next() % 26 == 0
                ))
                column += 1
                x += bedColumnPitch
            }
        }
        return chips
    }

    static func bedImage(width: CGFloat, height: CGFloat, slotHexes rawHexes: [String], scale: CGFloat) -> UIImage {
        let hexes = rawHexes.isEmpty ? [Constants.Color.textMute] : rawHexes
        let tones = hexes.map { GemTone(hex: $0, muted: true, glass: false) }
        let light = CGPoint(x: -0.6, y: 0.8)
        return UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: rendererFormat(scale: scale)
        ).image { renderer in
            let context = renderer.cgContext
            // Bed space is y-up from the floor; the image is y-down.
            func map(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: height - point.y) }

            let silhouette = CGMutablePath()
            silhouette.move(to: map(CGPoint(x: 0, y: 0)))
            var x: CGFloat = 0
            while x <= width {
                silhouette.addLine(to: map(CGPoint(x: x, y: bedProfile(x: x, width: width, height: height))))
                x += 2
            }
            silhouette.addLine(to: map(CGPoint(x: width, y: 0)))
            silhouette.closeSubpath()

            // Rounded floor corners follow the jar's inner wall.
            let corner = min(12, height * 0.5)
            context.addPath(CGPath(
                roundedRect: CGRect(x: 0, y: -corner, width: width, height: height + corner),
                cornerWidth: corner,
                cornerHeight: corner,
                transform: nil
            ))
            context.clip()

            // A dim ink ground (never brown) so gaps between chips do not
            // show the bare jar floor.
            let ink = GemColor(hex: "#15183A")
            let groundLight = tones[0].light
            let calm = tones[0].light.mixed(with: GemColor(hex: "#B8A6D9"), amount: 0.5)
            context.saveGState()
            context.addPath(silhouette)
            context.clip()
            if let ground = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    ink.withAlpha(0.58).cgColor,
                    ink.mixed(with: groundLight, amount: 0.35).withAlpha(0.30).cgColor,
                    groundLight.withAlpha(0).cgColor
                ] as CFArray,
                locations: [0, 0.6, 1]
            ) {
                context.drawLinearGradient(
                    ground,
                    start: map(CGPoint(x: 0, y: 0)),
                    end: map(CGPoint(x: 0, y: height)),
                    options: []
                )
            }
            context.restoreGState()

            let chips = bedChips(width: width, height: height)
            var sparkles: [(CGPoint, CGFloat, CGFloat)] = []
            // Back (upper) rows first, so lower chips overlap them.
            for chip in chips.reversed() {
                let top = bedProfile(x: chip.center.x, width: width, height: height)
                let depth = top - chip.center.y
                guard depth > chip.size * 0.15 else { continue }
                // Soft top edge: chips fade in over the top 30 % of the bed.
                let fade = min(1, depth / max(height * 0.30, 4))
                let alpha = pow(fade, 0.8) * 0.92
                let heightUnit = min(max(chip.center.y / max(height, 1), 0), 1)
                // Deeper chips sink into ink shade; the upper layer catches
                // the pile's light.
                let depthLight = 0.62 + 0.38 * heightUnit
                let tone = tones[chip.slot % tones.count]
                let count = chip.radii.count
                let points: [CGPoint] = (0 ..< count).map { index in
                    let angle = chip.rotation + CGFloat(index) / CGFloat(count) * .pi * 2
                    let r = chip.size / 2 * chip.radii[index]
                    return CGPoint(x: chip.center.x + cos(angle) * r, y: chip.center.y + sin(angle) * r * 0.80)
                }
                let apex = CGPoint(x: chip.center.x - chip.size * 0.10, y: chip.center.y + chip.size * 0.08)
                for index in 0 ..< count {
                    let a = points[index]
                    let b = points[(index + 1) % count]
                    var normal = CGPoint(x: b.y - a.y, y: -(b.x - a.x))
                    let length = max(0.001, hypot(normal.x, normal.y))
                    normal = CGPoint(x: normal.x / length, y: normal.y / length)
                    // Counter-clockwise points: the outward normal is (dy, -dx).
                    let facing = 0.5 + 0.5 * (normal.x * light.x + normal.y * light.y)
                    var color = tone.facet(brightness: min(1, 0.06 + 0.90 * pow(facing, 1.3) * chip.shade), hueJitter: 0)
                    if facing > 0.86 {
                        // The facet that faces the light glints pale.
                        color = color.mixed(with: tone.light, amount: 0.45)
                    }
                    // Calmer than any real gem: a quarter toward the bed's
                    // own light, so the ground reads as one glowing mass,
                    // not as confetti.
                    color = color.mixed(with: calm, amount: 0.24)
                    color = color.mixed(with: ink, amount: (1 - depthLight) * 0.85)
                    let path = CGMutablePath()
                    path.addLines(between: [map(apex), map(a), map(b)])
                    path.closeSubpath()
                    context.addPath(path)
                    context.setFillColor(color.withAlpha(alpha).cgColor)
                    context.fillPath()
                }
                let outline = CGMutablePath()
                outline.addLines(between: points.map(map))
                outline.closeSubpath()
                context.addPath(outline)
                context.setStrokeColor(tone.deep.darker(0.4).withAlpha(alpha * 0.45).cgColor)
                context.setLineWidth(0.45)
                context.strokePath()
                // A hairline of light on the chip's table.
                context.move(to: map(apex))
                context.addLine(to: map(points[0]))
                context.setStrokeColor(UIColor(white: 1, alpha: alpha * 0.22 * depthLight).cgColor)
                context.setLineWidth(0.4)
                context.strokePath()
                if chip.sparkle, fade > 0.45, heightUnit > 0.25 {
                    sparkles.append((map(apex), 1.8 + chip.size * 0.22, 0.50 * fade))
                }
            }

            // Soft top edge that melts into the jar's light.
            context.saveGState()
            context.addPath(silhouette)
            context.clip()
            let glow = tones[0].light.mixed(with: GemColor(hex: "#FFB38A"), amount: 0.35)
            if let haze = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    glow.withAlpha(0).cgColor,
                    glow.withAlpha(0.06).cgColor,
                    glow.withAlpha(0.20).cgColor,
                    glow.withAlpha(0).cgColor
                ] as CFArray,
                locations: [0, 0.45, 0.80, 1]
            ) {
                context.drawLinearGradient(
                    haze,
                    start: map(CGPoint(x: 0, y: 0)),
                    end: map(CGPoint(x: 0, y: height)),
                    options: []
                )
            }
            context.restoreGState()

            // Static sparkle: a handful of tiny stars, no animation.
            for (center, length, alpha) in sparkles {
                drawSparkle(context: context, center: center, length: length, alpha: alpha)
            }
        }
    }

    // MARK: Shared light textures (one draw batch each)

    /// Gaussian bloom: half maximum at about 1.2 × the gem radius for the
    /// standard 2.2–2.7 halo scales. Tinted per gem via `color`.
    static let haloTexture = sharedTexture(haloImage)
    static let haloImage: UIImage = sharedImage(pixels: 128) { context, size in
        let center = CGPoint(x: size / 2, y: size / 2)
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        // 0.55 of the sprite radius ≈ 1.2 × the gem radius at halo 2.2.
        let halfMaximum: CGFloat = 0.55
        for step in 0 ... 14 {
            let t = CGFloat(step) / 14
            let gaussian = exp(-log(2) * pow(t / halfMaximum, 2))
            let window = pow(max(0, 1 - t * t), 2)
            colors.append(UIColor(white: 1, alpha: gaussian * window).cgColor)
            locations.append(t)
        }
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) {
            context.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: size / 2,
                options: []
            )
        }
    }

    /// Four-point star with a soft core; additive, white. The horizontal arm
    /// is a little longer than the vertical one, like a lens flare.
    static let glintTexture = sharedTexture(glintImage)
    static let glintImage: UIImage = sharedImage(pixels: 128) { context, size in
        let center = CGPoint(x: size / 2, y: size / 2)
        let space = CGColorSpaceCreateDeviceRGB()
        let core = [
            UIColor(white: 1, alpha: 1).cgColor,
            UIColor(white: 1, alpha: 0.30).cgColor,
            UIColor(white: 1, alpha: 0).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: core, locations: [0, 0.35, 1]) {
            context.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: size * 0.14,
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
        ray(length: size * 0.5, width: size * 0.045, angle: 0, alpha: 1)
        ray(length: size * 0.34, width: size * 0.04, angle: .pi / 2, alpha: 0.9)
        ray(length: size * 0.16, width: size * 0.025, angle: .pi / 4, alpha: 0.45)
        ray(length: size * 0.16, width: size * 0.025, angle: -.pi / 4, alpha: 0.45)
    }

    /// Broad pool of light with a small flat plateau, used for
    /// the light the whole pile casts into the jar and onto its floor.
    static let poolTexture: SKTexture = sharedTexture(pixels: 128) { context, size in
        let center = CGPoint(x: size / 2, y: size / 2)
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        for step in 0 ... 14 {
            let t = CGFloat(step) / 14
            // Flat to 20 % of the radius, then a smoothstep to zero.
            let u = min(max((t - 0.20) / 0.80, 0), 1)
            colors.append(UIColor(white: 1, alpha: 1 - u * u * (3 - 2 * u)).cgColor)
            locations.append(t)
        }
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors as CFArray,
            locations: locations
        ) {
            context.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: size / 2,
                options: []
            )
        }
    }

    /// Soft thin ring for the fusion shock ring (additive, white).
    static let ringTexture: SKTexture = sharedTexture(pixels: 128) { context, size in
        let center = CGPoint(x: size / 2, y: size / 2)
        let colors = [
            UIColor(white: 1, alpha: 0).cgColor,
            UIColor(white: 1, alpha: 0.85).cgColor,
            UIColor(white: 1, alpha: 0).cgColor
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0.78, 0.90, 1]
        ) {
            context.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: size / 2,
                options: []
            )
        }
    }

    /// Soft contact shadow ellipse drawn in a square; the sprite squashes it.
    static let shadowTexture = sharedTexture(shadowImage)
    static let shadowImage: UIImage = sharedImage(pixels: 64) { context, size in
        let center = CGPoint(x: size / 2, y: size / 2)
        let colors = [
            UIColor(red: 0.01, green: 0.02, blue: 0.08, alpha: 0.9).cgColor,
            UIColor(red: 0.01, green: 0.02, blue: 0.08, alpha: 0.38).cgColor,
            UIColor(red: 0.01, green: 0.02, blue: 0.08, alpha: 0).cgColor
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

    /// Screen-fixed additive light (blend `.add`): the warm-white key sheen
    /// at the upper left (centre −0.28R, +0.34R; 0.62R × 0.40R), the warm rim
    /// on the upper-left edge and the cool bounce on the lower-left edge.
    /// Drawn in a square whose half side is the gem radius.
    static let lightRigAddTexture = sharedTexture(lightRigAddImage)
    static let lightRigAddImage: UIImage = sharedImage(pixels: 128) { context, size in
        let space = CGColorSpaceCreateDeviceRGB()
        let radius = size / 2
        // y-down texture space: unit (ux, uy up) → (radius + ux·r, radius − uy·r)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: radius + x * radius, y: radius - y * radius)
        }
        context.saveGState()
        context.addEllipse(in: CGRect(x: size * 0.03, y: size * 0.03, width: size * 0.94, height: size * 0.94))
        context.clip()

        // Warm rim arc (upper-left edge), #FFB38A α0.18.
        drawRimArc(
            context: context, space: space, center: point(0, 0), radius: radius * 0.93,
            angle: .pi * 0.75, spread: .pi * 0.30, width: radius * 0.16,
            color: GemColor(hex: "#FFB38A"), alpha: 0.18
        )
        // Cool bounce arc (lower-left edge), #8ACBFF α0.22.
        drawRimArc(
            context: context, space: space, center: point(0, 0), radius: radius * 0.93,
            angle: .pi * 1.22, spread: .pi * 0.24, width: radius * 0.18,
            color: GemColor(hex: "#8ACBFF"), alpha: 0.22
        )
        // Key sheen: #FFF3E6 α0.35 ellipse, softly falling off.
        let sheen = [
            GemColor(hex: "#FFF3E6").withAlpha(0.35).cgColor,
            GemColor(hex: "#FFF3E6").withAlpha(0.14).cgColor,
            GemColor(hex: "#FFF3E6").withAlpha(0).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: sheen, locations: [0, 0.55, 1]) {
            context.saveGState()
            let center = point(-0.28, 0.34)
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: -.pi / 5)
            context.scaleBy(x: 0.62, y: 0.40)
            context.drawRadialGradient(
                gradient,
                startCenter: .zero, startRadius: 0,
                endCenter: .zero, endRadius: radius,
                options: []
            )
            context.restoreGState()
        }
        context.restoreGState()
    }

    /// Screen-fixed pavilion shade (blend `.alpha`): a crescent at the lower
    /// right, black α0.16.
    static let lightRigShadeTexture = sharedTexture(lightRigShadeImage)
    static let lightRigShadeImage: UIImage = sharedImage(pixels: 128) { context, size in
        let space = CGColorSpaceCreateDeviceRGB()
        let radius = size / 2
        context.saveGState()
        context.addEllipse(in: CGRect(x: size * 0.03, y: size * 0.03, width: size * 0.94, height: size * 0.94))
        context.clip()
        let shade = [
            UIColor(white: 0, alpha: 0).cgColor,
            UIColor(white: 0, alpha: 0.16).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: shade, locations: [0, 1]) {
            context.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: radius * 0.80, y: radius * 0.78),
                startRadius: radius * 0.62,
                endCenter: CGPoint(x: radius * 0.92, y: radius * 0.90),
                endRadius: radius * 1.18,
                options: [.drawsAfterEndLocation]
            )
        }
        context.restoreGState()
    }

    /// Kept for callers that predate the split rig (tests, share previews):
    /// the additive part of the rig.
    static var keyLightTexture: SKTexture { lightRigAddTexture }

    private static func drawRimArc(
        context: CGContext,
        space: CGColorSpace,
        center: CGPoint,
        radius: CGFloat,
        angle: CGFloat,
        spread: CGFloat,
        width: CGFloat,
        color: GemColor,
        alpha: CGFloat
    ) {
        // A stroked arc with round caps, blurred by drawing a few widening
        // passes with falling alpha (cheap, baked once).
        context.saveGState()
        context.setLineCap(.round)
        for pass in 0 ..< 4 {
            let t = CGFloat(pass) / 3
            context.setStrokeColor(color.withAlpha(alpha * (1 - t * 0.72) / 2.2).cgColor)
            context.setLineWidth(width * (0.45 + t * 1.1))
            context.addArc(
                center: center,
                radius: radius - width * 0.3,
                // y-down space mirrors the angle.
                startAngle: -(angle + spread / 2),
                endAngle: -(angle - spread / 2),
                clockwise: false
            )
            context.strokePath()
        }
        context.restoreGState()
    }

    // MARK: Cache and sizing

    private static let bodyCache: NSCache<NSString, SKTexture> = {
        let cache = NSCache<NSString, SKTexture>()
        cache.name = "PomoGem.GemArtwork.body"
        cache.countLimit = 256
        cache.totalCostLimit = 12 * 1_024 * 1_024
        return cache
    }()

    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.name = "PomoGem.GemArtwork.image"
        cache.countLimit = 64
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    /// Bakes follow the display scale of the view that shows them (passed
    /// in by the caller), clamped to 1…3 so the cache stays bounded.
    static func renderScale(_ displayScale: CGFloat) -> CGFloat {
        guard displayScale.isFinite else { return 3 }
        return min(3, max(1, displayScale.rounded()))
    }

    private static func byteCost(_ image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }

    /// 1pt buckets below 16pt, 2pt above. Loose radii vary continuously with
    /// mass, so bucketing is what makes the cache hit.
    static func sizeBucket(radius: CGFloat) -> CGFloat {
        let clamped = max(4, radius)
        if clamped < 16 { return clamped.rounded(.up) }
        return (clamped / 2).rounded(.up) * 2
    }

    private static func margin(radius: CGFloat) -> CGFloat {
        max(1.5, radius * 0.08)
    }

    private static func rendererFormat(scale: CGFloat) -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = scale
        // 8-bit sRGB keeps the byte estimate honest on wide-colour devices.
        format.preferredRange = .standard
        return format
    }

    private static func sharedTexture(
        pixels: Int,
        draw: (CGContext, CGFloat) -> Void
    ) -> SKTexture {
        sharedTexture(sharedImage(pixels: pixels, draw: draw))
    }

    /// The shared light images are also packed into `GemTextureAtlas`, so
    /// every gem layer can batch with the bodies of the same blend mode.
    private static func sharedImage(
        pixels: Int,
        draw: (CGContext, CGFloat) -> Void
    ) -> UIImage {
        let size = CGFloat(pixels)
        return UIGraphicsImageRenderer(
            size: CGSize(width: size, height: size),
            format: rendererFormat(scale: 1)
        ).image { renderer in
            draw(renderer.cgContext, size)
        }
    }

    private static func sharedTexture(_ image: UIImage) -> SKTexture {
        let texture = SKTexture(image: image)
        texture.filteringMode = .linear
        return texture
    }

    // MARK: Layouts (unit space, y up)

    fileprivate struct Facet {
        var points: [CGPoint]
        /// True 3D facet normal; z is the cosine to the viewer.
        var normal: (x: CGFloat, y: CGFloat, z: CGFloat)
        /// Deterministic per-facet scintillation value h_f in 0...1.
        var shade: CGFloat
        /// Outermost band (receives the thin girdle fire tint).
        var isGirdle = false
        var isTable = false
    }

    fileprivate struct Layout {
        let outer: [CGPoint]
        let facets: [Facet]
    }

    private static let layoutLock = NSLock()
    nonisolated(unsafe) private static var layoutCache: [String: Layout] = [:]

    private static func layout(cut: GemCut, symmetry: Int, variant: Int) -> Layout {
        let key = "\(cut.rawValue)-\(symmetry)-\(variant)"
        layoutLock.lock()
        if let cached = layoutCache[key] {
            layoutLock.unlock()
            return cached
        }
        layoutLock.unlock()

        let raw: Layout
        switch cut {
        case .tumbled, .glass:
            raw = geodesicLayout(frequency: 2, variant: variant, salt: 0x6E4D)
        case .rough:
            raw = roughLayout(variant: variant)
        case .step:
            raw = stepLayout(symmetry: symmetry)
        case .brilliant, .radiant:
            raw = brilliantLayout(symmetry: symmetry)
        case .hero:
            raw = heroLayout()
        }
        let normalized = normalize(raw)
        layoutLock.lock()
        layoutCache[key] = normalized
        layoutLock.unlock()
        return normalized
    }

    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 2 else { return 0 }
        var sum: CGFloat = 0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Scale factor that brings a silhouette to the shared area ratio,
    /// capped so no vertex leaves 1.02 × the physics radius.
    private static func normalizationScale(for outer: [CGPoint]) -> (scale: CGFloat, capped: Bool) {
        let area = max(polygonArea(outer), 0.000_1)
        let wanted = (silhouetteAreaRatio * .pi / area).squareRoot()
        let maximumRadius = outer.map { hypot($0.x, $0.y) }.max() ?? 1
        let cap = silhouetteMaximumRadius / max(maximumRadius, 0.000_1)
        return (min(wanted, cap), wanted > cap + 0.000_1)
    }

    private static func normalize(_ layout: Layout) -> Layout {
        let scale = normalizationScale(for: layout.outer).scale
        func scaled(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scale, y: point.y * scale) }
        return Layout(
            outer: layout.outer.map(scaled),
            facets: layout.facets.map { facet in
                var copy = facet
                copy.points = facet.points.map(scaled)
                return copy
            }
        )
    }

    /// Self-reported gems keep the plain icosahedron, seen along a five-fold
    /// axis: a regular decagon silhouette that reaches the shared area ratio
    /// inside the 1.02 radius cap. Variants differ by a small tilt and roll.
    private static func roughLayout(variant: Int) -> Layout {
        let t = (1 + sqrt(CGFloat(5))) / 2
        let axisPitch = atan2(1, t)
        let tilt = (CGFloat(variant % 2) - 0.5) * 0.10
        let roll = CGFloat(variant) * .pi / 10 + 0.17
        return geodesicLayout(frequency: 1, variant: variant, salt: 0x2B0B) { vertex in
            var (x, y, z) = vertex
            // Bring the vertex (0, 1, φ) onto the view axis, then vary.
            let pitch = axisPitch + tilt
            (y, z) = (y * cos(pitch) - z * sin(pitch), y * sin(pitch) + z * cos(pitch))
            (x, y) = (x * cos(roll) - y * sin(roll), x * sin(roll) + y * cos(roll))
            return (x, y, z)
        }
    }

    /// Geodesic crystal: a subdivided icosahedron, rotated per variant and
    /// seen orthographically. Every facet carries its real normal, so the
    /// view-direction shading and Fresnel rim are physically coherent. The
    /// silhouette is the convex hull of the projected vertices.
    private static func geodesicLayout(
        frequency: Int,
        variant: Int,
        salt: Int,
        orientation: (((CGFloat, CGFloat, CGFloat)) -> (x: CGFloat, y: CGFloat, z: CGFloat))? = nil
    ) -> Layout {
        let mesh = icosphere(frequency: frequency)
        var random = GemRandom(seed: UInt64(salt &* 7_919 &+ variant &* 104_729 &+ 17))
        let yaw = random.unit() * .pi * 2
        let pitch = (random.unit() - 0.5) * 1.1
        let roll = random.unit() * .pi * 2
        func rotate(_ v: (CGFloat, CGFloat, CGFloat)) -> (x: CGFloat, y: CGFloat, z: CGFloat) {
            var (x, y, z) = v
            (x, y) = (x * cos(roll) - y * sin(roll), x * sin(roll) + y * cos(roll))
            (y, z) = (y * cos(pitch) - z * sin(pitch), y * sin(pitch) + z * cos(pitch))
            (x, z) = (x * cos(yaw) + z * sin(yaw), -x * sin(yaw) + z * cos(yaw))
            return (x, y, z)
        }
        let vertices = mesh.vertices.map(orientation ?? rotate)
        var shadeRandom = GemRandom(seed: UInt64(0x5EED &+ variant &* 7_919 &+ salt))
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
            let shade = shadeRandom.unit()
            guard n.z > 0.02 else { continue }
            facets.append(Facet(
                points: [CGPoint(x: a.x, y: a.y), CGPoint(x: b.x, y: b.y), CGPoint(x: c.x, y: c.y)],
                normal: n,
                shade: shade,
                isGirdle: n.z < 0.35
            ))
        }
        let hull = convexHull(vertices.map { CGPoint(x: $0.x, y: $0.y) })
        return Layout(outer: hull, facets: facets)
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

    private static func polar(_ angle: CGFloat, _ radius: CGFloat) -> CGPoint {
        CGPoint(x: cos(angle) * radius, y: sin(angle) * radius)
    }

    /// Normal of a facet tilted `slope` (0 = flat table, 1 = steep) toward
    /// the direction of its centroid.
    private static func slopedNormal(points: [CGPoint], slope: CGFloat) -> (x: CGFloat, y: CGFloat, z: CGFloat) {
        let centroid = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let direction = atan2(centroid.y, centroid.x)
        let tilt = slope * .pi / 2.9
        return (cos(direction) * sin(tilt), sin(direction) * sin(tilt), cos(tilt))
    }

    private static func ring(count: Int, radius: CGFloat, offset: CGFloat) -> [CGPoint] {
        (0 ..< count).map { index in
            polar(.pi / 2 + offset + CGFloat(index) / CGFloat(count) * .pi * 2, radius)
        }
    }

    /// Octagonal step cut: four stepped bands and a large table. Shades
    /// alternate in mirror-symmetric pairs, like steps catching the light.
    private static func stepLayout(symmetry rawSymmetry: Int) -> Layout {
        let count = max(6, rawSymmetry)
        let offset = CGFloat.pi / CGFloat(count)
        let scales: [CGFloat] = [1, 0.84, 0.70, 0.57, 0.45]
        let slopes: [CGFloat] = [0.90, 0.70, 0.50, 0.30]
        let bandShades: [(CGFloat, CGFloat)] = [(0.28, 0.58), (0.78, 0.46), (0.40, 0.86), (0.92, 0.60)]
        let rings = scales.map { ring(count: count, radius: $0, offset: offset) }
        var facets: [Facet] = []
        for band in 0 ..< 4 {
            let outer = rings[band]
            let inner = rings[band + 1]
            for index in outer.indices {
                let next = (index + 1) % outer.count
                let points = [outer[index], outer[next], inner[next], inner[index]]
                let shades = bandShades[band]
                facets.append(Facet(
                    points: points,
                    normal: slopedNormal(points: points, slope: slopes[band]),
                    shade: index.isMultiple(of: 2) ? shades.0 : shades.1,
                    isGirdle: band == 0
                ))
            }
        }
        // Table split into a mirrored bow-tie of pavilion reflections.
        let table = rings[4]
        for index in table.indices {
            let next = (index + 1) % table.count
            let points = [CGPoint.zero, table[index], table[next]]
            facets.append(Facet(
                points: points,
                normal: (0, 0, 1),
                shade: (index / 2).isMultiple(of: 2) ? 0.95 : 0.50,
                isTable: true
            ))
        }
        return Layout(outer: rings[0], facets: facets)
    }

    /// Round brilliant (A2) and radiant (A3/A4): table triangles, stars,
    /// kites and split girdle facets, alternating in two values (0.42/0.88)
    /// with mirror symmetry so the stone reads as cut, not as a mosaic.
    private static func brilliantLayout(symmetry rawSymmetry: Int) -> Layout {
        let count = max(6, rawSymmetry)
        let step = CGFloat.pi * 2 / CGFloat(count)
        let start = CGFloat.pi / 2
        let table = (0 ..< count).map { polar(start + CGFloat($0) * step, 0.50) }
        let stars = (0 ..< count).map { polar(start + (CGFloat($0) + 0.5) * step, 0.77) }
        let girdle = (0 ..< count * 2).map { polar(start + CGFloat($0) * step / 2, 1) }
        var facets: [Facet] = []
        for index in 0 ..< count {
            let next = (index + 1) % count
            let previous = (index + count - 1) % count
            let even = index.isMultiple(of: 2)
            let tablePoints = [CGPoint.zero, table[index], table[next]]
            facets.append(Facet(
                points: tablePoints, normal: (0, 0, 1),
                shade: even ? 0.88 : 0.42, isTable: true
            ))
            let starPoints = [table[index], table[next], stars[index]]
            facets.append(Facet(
                points: starPoints, normal: slopedNormal(points: starPoints, slope: 0.36),
                shade: even ? 0.52 : 0.80
            ))
            let kitePoints = [table[index], stars[previous], girdle[index * 2], stars[index]]
            facets.append(Facet(
                points: kitePoints, normal: slopedNormal(points: kitePoints, slope: 0.60),
                shade: even ? 0.88 : 0.42
            ))
            let leftGirdle = [stars[index], girdle[index * 2], girdle[index * 2 + 1]]
            facets.append(Facet(
                points: leftGirdle, normal: slopedNormal(points: leftGirdle, slope: 0.86),
                shade: 0.36, isGirdle: true
            ))
            let rightGirdle = [stars[index], girdle[index * 2 + 1], girdle[(index * 2 + 2) % (count * 2)]]
            facets.append(Facet(
                points: rightGirdle, normal: slopedNormal(points: rightGirdle, slope: 0.86),
                shade: 0.66, isGirdle: true
            ))
        }
        return Layout(outer: girdle, facets: facets)
    }

    /// Decagonal hero outline (the time core's silhouette, shared with the
    /// outline tests). The core itself is painted by `renderHero` on its own
    /// radial geometry (`CoreGeometry`) with the same ten girdle vertices.
    private static func heroLayout() -> Layout {
        let count = 10
        let step = CGFloat.pi * 2 / CGFloat(count)
        let start = CGFloat.pi / 2
        let table = (0 ..< count).map { polar(start + CGFloat($0) * step, 0.42) }
        let inner = (0 ..< count).map { polar(start + (CGFloat($0) + 0.5) * step, 0.78) }
        let outer = (0 ..< count).map { polar(start + CGFloat($0) * step, 1) }
        var facets: [Facet] = [
            Facet(points: table, normal: (0, 0, 1), shade: 0.9, isTable: true)
        ]
        for index in 0 ..< count {
            let next = (index + 1) % count
            let previous = (index + count - 1) % count
            let star = [table[index], table[next], inner[index]]
            facets.append(Facet(points: star, normal: slopedNormal(points: star, slope: 0.30), shade: 0.7))
            let kite = [table[index], inner[previous], outer[index], inner[index]]
            facets.append(Facet(points: kite, normal: slopedNormal(points: kite, slope: 0.62), shade: 1, isGirdle: true))
            let girdleFacet = [outer[index], outer[next], inner[index]]
            facets.append(Facet(points: girdleFacet, normal: slopedNormal(points: girdleFacet, slope: 0.86), shade: 0.55, isGirdle: true))
        }
        return Layout(outer: outer, facets: facets)
    }

    // MARK: Rendering

    private static func renderBody(spec: GemArtworkSpec, radius: CGFloat, scale: CGFloat) -> UIImage {
        let pad = margin(radius: radius)
        let side = (radius + pad) * 2
        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: rendererFormat(scale: scale)
        ).image { renderer in
            let center = CGPoint(x: side / 2, y: side / 2)
            // Unit space is y-up; UIKit image space is y-down.
            func map(_ point: CGPoint) -> CGPoint {
                CGPoint(x: center.x + point.x * radius, y: center.y - point.y * radius)
            }
            drawGem(spec: spec, context: renderer.cgContext, radius: radius, map: map)
        }
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(max(points.count, 1)), y: sum.y / CGFloat(max(points.count, 1)))
    }

    private static func drawGem(
        spec: GemArtworkSpec,
        context: CGContext,
        radius: CGFloat,
        map: (CGPoint) -> CGPoint
    ) {
        let space = CGColorSpaceCreateDeviceRGB()
        let gemLayout = layout(cut: spec.cut, symmetry: spec.symmetry, variant: spec.variant)
        let outlinePath = CGMutablePath()
        outlinePath.addLines(between: gemLayout.outer.map(map))
        outlinePath.closeSubpath()

        let isGlass = spec.cut == .glass
        let tones = SectorTones(spec: spec)
        let dominant = tones.dominant
        let contrast = min(max(spec.facetContrast + dominant.contrastBoost, 0), 1)
        let jitterLimit: CGFloat = spec.cut == .brilliant || spec.cut == .radiant ? 0.12 : 0.18
        var jitter = GemRandom(seed: UInt64(0xF1CE &+ spec.variant &* 131 &+ spec.symmetry))

        context.saveGState()
        context.addPath(outlinePath)
        context.clip()

        // 1. Body: the deep tone shows through hairline gaps.
        context.setFillColor(dominant.deep.cgColor)
        context.addPath(outlinePath)
        context.fillPath()

        // 2. Facets: view-direction shading only, so rotation never moves a
        //    baked highlight. b = lerp(1 − 0.7c, 1, h) × (0.55 + 0.45·nz^0.6).
        for facet in gemLayout.facets {
            let nz = min(max(facet.normal.z, 0), 1)
            var shade = facet.shade
            if facet.isTable || spec.cut != .tumbled {
                shade += (jitter.unit() - 0.5) * 2 * jitterLimit * (1 - facet.shade * 0.4) * 0.5
            }
            shade = min(max(shade, 0), 1)
            let floor = 1 - 0.7 * contrast
            var brightness = (floor + (1 - floor) * shade) * (0.55 + 0.45 * pow(nz, 0.6))
            if spec.isMuted { brightness = 0.25 + brightness * 0.7 }
            brightness = min(max(brightness, 0.08), 1)

            let center = centroid(facet.points)
            let tone = tones.tone(atAngle: atan2(center.y, center.x))
            var color = tone.facet(brightness: brightness, hueJitter: shade * 2 - 1)
            // Fresnel rim: (1 − N·V)^3 × 0.35 toward white/#8ACBFF.
            let fresnel = pow(1 - nz, 3) * 0.35 * (isGlass ? 1.2 : 1)
            color = color.mixed(with: GemColor.fresnelTint, amount: fresnel)
            // A whisper of fire in the girdle band only (A1+ cut stones).
            if facet.isGirdle, !spec.isMuted, !isGlass, spec.cut != .tumbled, spec.cut != .rough {
                let fire = [GemColor.fireWarm, GemColor.fireCool, GemColor.fireViolet]
                let index = Int((center.x * 997 + center.y * 131).magnitude * 10) % fire.count
                color = color.mixed(with: fire[index], amount: 0.14)
            }

            let mapped = facet.points.map(map)
            let path = CGMutablePath()
            path.addLines(between: mapped)
            path.closeSubpath()
            // Radial (rotation-invariant) gradient across the facet: the
            // inner edge slightly lighter than the outer edge.
            let byDistance = mapped.sorted {
                hypot($0.x - map(.zero).x, $0.y - map(.zero).y)
                    < hypot($1.x - map(.zero).x, $1.y - map(.zero).y)
            }
            let gradientColors = [
                color.lighter(0.07).cgColor,
                color.cgColor,
                color.darker(0.10).cgColor
            ] as CFArray
            context.saveGState()
            context.addPath(path)
            context.clip()
            if let first = byDistance.first, let last = byDistance.last,
               hypot(first.x - last.x, first.y - last.y) > 0.01,
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

        // 3. Inner glow: the light tone gathered in the middle, α0.45 → 0
        //    at 0.7R (lit from within).
        let glow = dominant.light
        context.saveGState()
        context.setBlendMode(.screen)
        let glowAlpha: CGFloat = spec.isMuted ? 0.22 : (isGlass ? 0.30 : 0.50)
        let glowColors = [
            glow.withAlpha(glowAlpha).cgColor,
            glow.withAlpha(glowAlpha * 0.40).cgColor,
            glow.withAlpha(0).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: glowColors, locations: [0, 0.5, 1]) {
            context.drawRadialGradient(
                gradient,
                startCenter: map(.zero), startRadius: 0,
                endCenter: map(.zero), endRadius: radius * 0.75,
                options: []
            )
        }
        context.restoreGState()

        // Pin-point lights where facets meet (tumbled crystals): tiny, many,
        // spread over the whole stone so they add sparkle without a side.
        if spec.cut == .tumbled, !spec.isMuted, radius >= 6 {
            var seen = Set<Int>()
            var pins: [CGPoint] = []
            for facet in gemLayout.facets where facet.normal.z > 0.45 {
                for point in facet.points {
                    let key = Int((point.x * 500).rounded()) * 4_099 + Int((point.y * 500).rounded())
                    if seen.insert(key).inserted { pins.append(point) }
                }
            }
            let stride = max(1, pins.count / 7)
            for (index, point) in pins.enumerated() where index % stride == spec.variant % stride {
                drawDot(context: context, center: map(point), radius: max(0.35, radius * 0.028), alpha: 0.75)
            }
        }

        // 4. A3+: a white heart in the table.
        if spec.hasWhiteCore {
            context.saveGState()
            context.setBlendMode(.screen)
            let heart = [
                UIColor(white: 1, alpha: 0.80).cgColor,
                UIColor(white: 1, alpha: 0.30).cgColor,
                UIColor(white: 1, alpha: 0).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: heart, locations: [0, 0.45, 1]) {
                context.drawRadialGradient(
                    gradient,
                    startCenter: map(.zero), startRadius: 0,
                    endCenter: map(.zero), endRadius: radius * 0.25,
                    options: []
                )
            }
            context.restoreGState()
        }

        // 5. Facet edges: hairline internal edges in the light tone.
        let internalWidth = min(max(radius * 0.035, 0.35), 0.6)
        let edgeAlpha = min(1, (isGlass ? 0.34 : (spec.isMuted ? 0.14 : 0.28)) + spec.edgeBoost)
        context.setLineJoin(.round)
        context.setStrokeColor(dominant.light.mixed(with: .white, amount: 0.5).withAlpha(edgeAlpha).cgColor)
        context.setLineWidth(internalWidth)
        for facet in gemLayout.facets {
            let path = CGMutablePath()
            path.addLines(between: facet.points.map(map))
            path.closeSubpath()
            context.addPath(path)
        }
        context.strokePath()

        // 6. Baked micro sparkles: rotationally symmetric so the texture has
        //    no preferred light direction.
        if spec.sparkleCount > 0, !spec.isMuted {
            let count = spec.sparkleCount
            let phase = CGFloat(spec.variant) * 0.61 + 0.35
            for index in 0 ..< count {
                let point: CGPoint
                if count == 1 {
                    point = .zero
                } else {
                    let angle = phase + CGFloat(index) / CGFloat(count) * .pi * 2
                    point = polar(angle, 0.52)
                }
                drawSparkle(
                    context: context,
                    center: map(point),
                    length: radius * (count == 1 ? 0.16 : 0.13),
                    alpha: 0.80
                )
            }
        }
        // A4: crown of small lights around the table.
        if spec.hasCrown {
            let count = max(6, spec.symmetry)
            for index in 0 ..< count {
                let angle = .pi / 2 + CGFloat(index) / CGFloat(count) * .pi * 2
                drawDot(context: context, center: map(polar(angle, 0.52)), radius: max(0.6, radius * 0.035), alpha: 0.9)
            }
        }
        context.restoreGState() // outline clip

        // 7. Girdle outline, white α0.75.
        let outlineAlpha = min(1, (isGlass ? 0.55 : (spec.isMuted ? 0.36 : 0.75)) + spec.edgeBoost)
        context.addPath(outlinePath)
        context.setStrokeColor(UIColor(white: 1, alpha: outlineAlpha).cgColor)
        context.setLineWidth(min(max(radius * 0.06, 0.6), 1.0))
        context.strokePath()

        // 8. Achievement setting: four copper prongs (4-fold symmetric).
        if spec.hasProngs {
            drawProngs(context: context, radius: radius, map: map)
        }

        // 9. Self-reported fairness ring (existing semantic marker).
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
    }

    private static func drawProngs(context: CGContext, radius: CGFloat, map: (CGPoint) -> CGPoint) {
        let base = GemColor(hex: "#B8735A")
        let highlight = GemColor(hex: "#F2C4A8")
        let shade = GemColor(hex: "#5A2E22")
        let width = radius * 0.24
        for index in 0 ..< 4 {
            let angle = CGFloat.pi / 4 + CGFloat(index) * .pi / 2
            let inner = polar(angle, 0.80)
            let outer = polar(angle, 1.04)
            let side = CGPoint(x: -sin(angle) * width / radius / 2, y: cos(angle) * width / radius / 2)
            let path = CGMutablePath()
            path.move(to: map(CGPoint(x: inner.x - side.x * 0.6, y: inner.y - side.y * 0.6)))
            path.addLine(to: map(CGPoint(x: outer.x - side.x, y: outer.y - side.y)))
            path.addLine(to: map(CGPoint(x: outer.x + side.x, y: outer.y + side.y)))
            path.addLine(to: map(CGPoint(x: inner.x + side.x * 0.6, y: inner.y + side.y * 0.6)))
            path.closeSubpath()
            context.saveGState()
            context.addPath(path)
            context.clip()
            let colors = [highlight.cgColor, base.cgColor, shade.cgColor] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.45, 1]
            ) {
                context.drawLinearGradient(
                    gradient,
                    start: map(CGPoint(x: outer.x - side.x, y: outer.y - side.y)),
                    end: map(CGPoint(x: outer.x + side.x, y: outer.y + side.y)),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
            context.restoreGState()
            context.addPath(path)
            context.setStrokeColor(shade.withAlpha(0.8).cgColor)
            context.setLineWidth(max(0.4, radius * 0.02))
            context.strokePath()
        }
    }

    private static func drawSparkle(
        context: CGContext,
        center: CGPoint,
        length: CGFloat,
        alpha: CGFloat,
        rotation: CGFloat = 0
    ) {
        context.saveGState()
        context.setBlendMode(.screen)
        if rotation != 0 {
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: rotation)
            context.translateBy(x: -center.x, y: -center.y)
        }
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
        drawDot(context: context, center: center, radius: length * 0.35, alpha: alpha)
    }

    private static func drawDot(context: CGContext, center: CGPoint, radius: CGFloat, alpha: CGFloat) {
        context.saveGState()
        context.setBlendMode(.screen)
        let colors = [
            UIColor(white: 1, alpha: alpha).cgColor,
            UIColor(white: 1, alpha: 0).cgColor
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawRadialGradient(
                gradient,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: radius * 2,
                options: []
            )
        }
        context.restoreGState()
    }

    // MARK: Time core v3 (luminous radial brilliant)

    /// The twenty colour slots of the core, clockwise from 12 o'clock, as
    /// the theme-share fan paints them (top five + その他, 5 % steps). The
    /// twenty radial facets between the heart and the crown take exactly
    /// these colours; there is no fixed hue sweep.
    static func coreSlotHexes(shares: [GemColorShare]) -> [String] {
        let quantized = quantizedCoreShares(shares)
        var slots: [String] = []
        for share in quantized {
            slots += Array(repeating: share.hex, count: max(1, Int((share.fraction * 20).rounded())))
        }
        if slots.isEmpty { slots = [Constants.Color.textMute] }
        while slots.count < 20 { slots.append(slots[slots.count - 1]) }
        return Array(slots.prefix(20))
    }

    /// Unit-space geometry of the core (girdle vertex radius 1, y up). Ten
    /// girdle vertices start at 12 o'clock. The crown ring has a point under
    /// every girdle vertex and one in every sector's middle, so the twenty
    /// radial facets from the heart to the crown are the twenty 5 % slots.
    fileprivate enum CoreGeometry {
        static let crownVertexRadius: CGFloat = 0.74
        static let crownMidRadius: CGFloat = 0.82

        /// Math angle of slot boundary `b` (clockwise from 12 o'clock, 18° each).
        static func angle(boundary: Int) -> CGFloat {
            .pi / 2 - CGFloat(boundary) * (.pi / 10)
        }

        static func girdle(_ index: Int) -> CGPoint {
            GemArtwork.polar(angle(boundary: 2 * (index % 10)), 1)
        }

        /// Crown ring point at slot boundary `b`: even → under a girdle
        /// vertex, odd → the sector's middle.
        static func crown(_ boundary: Int) -> CGPoint {
            let b = boundary % 20
            return GemArtwork.polar(angle(boundary: b), b.isMultiple(of: 2) ? crownVertexRadius : crownMidRadius)
        }

        static var outline: [CGPoint] { (0 ..< 10).map(girdle) }
    }

    /// Luminous tones of one slot, heart → girdle: near-white heart, pale
    /// light, saturated mid, deeper edge (never brown), and the pale lit
    /// crown. `parity` 1 is the second half of a sector: a few degrees
    /// warmer and a step deeper, so even a single-theme core sparkles.
    fileprivate struct CoreSlotTones {
        let heart: GemColor
        let light: GemColor
        let vivid: GemColor
        let deep: GemColor
        let crown: GemColor

        init(hex: String, slot: Int, vessel: Bool, lit: Bool) {
            let parity = slot % 2
            // Sector-wise hue breathing (±4°) and a key light from the upper
            // left (±7 %), fixed per slot so the bake is deterministic.
            let sector = slot / 2
            let jitter: [CGFloat] = [0, 3, -2, 4, -3, 1, -4, 2, -1, 3]
            let center = CoreGeometry.angle(boundary: slot) - .pi / 20
            let key = cos(center - .pi * 0.75)
            let lightFactor = 1 + 0.07 * key
            if vessel {
                let glassLight = lit ? GemColor(red: 0.96, green: 0.99, blue: 1) : GemColor(red: 0.52, green: 0.58, blue: 0.70)
                let glassMid = lit ? GemColor(red: 0.84, green: 0.93, blue: 1) : GemColor(red: 0.28, green: 0.33, blue: 0.45)
                let glassDeep = lit ? GemColor(red: 0.66, green: 0.80, blue: 1) : GemColor(red: 0.14, green: 0.17, blue: 0.27)
                let shade: CGFloat = parity == 0 ? 1 : 0.84
                heart = glassLight.lighter(0.5)
                light = glassLight.darker(1 - shade * lightFactor)
                vivid = glassMid.darker(1 - shade * lightFactor)
                deep = glassDeep.darker(1 - shade)
                crown = glassMid.lighter(lit ? 0.35 : 0.22)
                return
            }
            let tone = GemTone(hex: hex, muted: false, glass: false)
            let neutral = tone.saturation < 0.08
            let hue = tone.hue + (jitter[sector] + (parity == 0 ? 0 : 7)) / 360
            let saturation = neutral ? tone.saturation : min(0.82, max(0.68, tone.saturation * 0.94))
            let shade: CGFloat = (parity == 0 ? 1 : 0.86) * lightFactor
            vivid = GemColor(hue: hue, saturation: parity == 0 ? saturation : min(1, saturation + 0.08), brightness: min(1, shade))
            deep = GemColor(
                hue: hue - 5 / 360,
                saturation: neutral ? saturation : min(1, saturation + 0.14),
                brightness: (parity == 0 ? 0.90 : 0.77) * lightFactor
            )
            light = GemColor(
                hue: hue + tone.lightHueShift,
                saturation: neutral ? saturation : (parity == 0 ? 0.34 : 0.42),
                brightness: 1
            )
            heart = light.lighter(0.72)
            crown = vivid.mixed(with: .white, amount: parity == 0 ? 0.60 : 0.48)
        }
    }

    /// Time core v3 (Docs/GemExperienceDesign.md §7.9): a luminous radial
    /// brilliant. Twenty radial facets (ten sectors, each split in a lighter
    /// and a deeper half) run from a white-hot heart through saturated
    /// colour to a deeper edge; a crown ring of thirty small pale facets, a
    /// bright girdle, an additive dispersion fringe and a crisp specular
    /// streak at the upper left. Colours come only from the share fan. The
    /// core never rotates, so directional light is allowed here.
    private static func renderHero(
        shares: [GemColorShare],
        level: Int,
        litVesselFacets: Int?,
        scale: CGFloat
    ) -> UIImage {
        let diameter = coreBakeDiameter
        let radius = diameter / 2 - margin(radius: diameter / 2)
        let side = diameter
        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: rendererFormat(scale: scale)
        ).image { renderer in
            let context = renderer.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let center = CGPoint(x: side / 2, y: side / 2)
            func map(_ point: CGPoint) -> CGPoint {
                CGPoint(x: center.x + point.x * radius, y: center.y - point.y * radius)
            }
            func polygon(_ points: [CGPoint]) -> CGPath {
                let path = CGMutablePath()
                path.addLines(between: points.map(map))
                path.closeSubpath()
                return path
            }
            func gradient(_ colors: [UIColor], _ locations: [CGFloat]) -> CGGradient? {
                CGGradient(colorsSpace: space, colors: colors.map(\.cgColor) as CFArray, locations: locations)
            }
            let isVessel = litVesselFacets != nil
            let litSectors = min(max(litVesselFacets ?? 0, 0), 10)
            let hexes = isVessel ? Array(repeating: "#DCEBFF", count: 20) : coreSlotHexes(shares: shares)
            let tones = (0 ..< 20).map { slot in
                CoreSlotTones(hex: hexes[slot], slot: slot, vessel: isVessel, lit: slot / 2 < litSectors)
            }
            let outline = polygon(CoreGeometry.outline)

            context.saveGState()
            context.addPath(outline)
            context.clip()
            context.setFillColor(tones[0].deep.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))

            // 1. Twenty radial facets: heart → light → vivid → deep.
            for slot in 0 ..< 20 {
                let tone = tones[slot]
                let facet = [CGPoint.zero, CoreGeometry.crown(slot), CoreGeometry.crown(slot + 1)]
                context.saveGState()
                context.addPath(polygon(facet))
                context.clip()
                if let fill = gradient(
                    [
                        tone.heart.withAlpha(1),
                        tone.light.withAlpha(1),
                        tone.vivid.withAlpha(1),
                        tone.vivid.mixed(with: tone.deep, amount: 0.45).withAlpha(1),
                        tone.deep.withAlpha(1)
                    ],
                    [0, 0.24, 0.60, 0.88, 1]
                ) {
                    context.drawRadialGradient(
                        fill,
                        startCenter: map(.zero), startRadius: 0,
                        endCenter: map(.zero), endRadius: radius * CoreGeometry.crownMidRadius,
                        options: [.drawsAfterEndLocation]
                    )
                }
                // Glassy sheen across the facet: its leading spoke catches
                // more light than its trailing one.
                if let sheen = gradient(
                    [UIColor(white: 1, alpha: slot.isMultiple(of: 2) ? 0.16 : 0.04), UIColor(white: 1, alpha: 0)],
                    [0, 1]
                ) {
                    context.setBlendMode(.screen)
                    context.drawLinearGradient(
                        sheen,
                        start: map(CoreGeometry.crown(slot)),
                        end: map(CoreGeometry.crown(slot + 1)),
                        options: []
                    )
                }
                context.restoreGState()
            }

            // 2. Crown ring: thirty small pale facets, lit toward the girdle.
            for sector in 0 ..< 10 {
                let first = tones[2 * sector]
                let second = tones[2 * sector + 1]
                let outerA = CoreGeometry.girdle(sector)
                let outerB = CoreGeometry.girdle(sector + 1)
                let vertexA = CoreGeometry.crown(2 * sector)
                let middle = CoreGeometry.crown(2 * sector + 1)
                let vertexB = CoreGeometry.crown(2 * sector + 2)
                let bezelInner = first.vivid.mixed(with: second.vivid, amount: 0.5)
                let facets: [([CGPoint], GemColor, GemColor)] = [
                    ([outerA, middle, vertexA], first.crown.mixed(with: first.vivid, amount: 0.30), first.crown.lighter(0.30)),
                    ([outerA, outerB, middle], bezelInner.mixed(with: first.deep, amount: 0.12), bezelInner.lighter(0.48)),
                    ([outerB, vertexB, middle], second.crown.mixed(with: second.vivid, amount: 0.38), second.crown.lighter(0.18))
                ]
                for (points, inner, outer) in facets {
                    context.saveGState()
                    context.addPath(polygon(points))
                    context.clip()
                    let innerPoint = centroid(points).scaled(0.84)
                    let outerPoint = centroid(points).scaled(1.12)
                    if let fill = gradient([inner.withAlpha(1), outer.withAlpha(1)], [0, 1]) {
                        context.drawLinearGradient(
                            fill,
                            start: map(innerPoint),
                            end: map(outerPoint),
                            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                        )
                    }
                    context.restoreGState()
                }
            }

            // 3. White-hot heart.
            context.saveGState()
            context.setBlendMode(.screen)
            if let heart = gradient(
                [
                    UIColor(white: 1, alpha: 1),
                    UIColor(white: 1, alpha: isVessel ? 0.50 : 0.80),
                    UIColor(white: 1, alpha: isVessel ? 0.12 : 0.22),
                    UIColor(white: 1, alpha: isVessel ? 0.02 : 0.05),
                    UIColor(white: 1, alpha: 0)
                ],
                [0, 0.10, 0.30, 0.62, 1]
            ) {
                context.drawRadialGradient(
                    heart,
                    startCenter: map(.zero), startRadius: 0,
                    endCenter: map(.zero), endRadius: radius * 0.44,
                    options: []
                )
            }
            context.restoreGState()

            // 4. Facet edges: bright spokes that fade toward the crown, finer
            // mid-spokes, and the crown ring.
            for boundary in 0 ..< 20 {
                let tip = map(CoreGeometry.crown(boundary))
                let major = boundary.isMultiple(of: 2)
                drawSpoke(
                    context: context,
                    from: map(.zero),
                    to: tip,
                    width: radius * (major ? 0.018 : 0.009),
                    alphas: major ? (0.95, 0.50) : (0.34, 0.08)
                )
            }
            context.setLineJoin(.round)
            context.setStrokeColor(UIColor(white: 1, alpha: isVessel ? 0.45 : 0.55).cgColor)
            context.setLineWidth(max(0.6, radius * 0.012))
            context.addPath(polygon((0 ..< 20).map(CoreGeometry.crown)))
            context.strokePath()
            context.setStrokeColor(UIColor(white: 1, alpha: isVessel ? 0.36 : 0.40).cgColor)
            context.setLineWidth(max(0.5, radius * 0.009))
            for sector in 0 ..< 10 {
                let middle = map(CoreGeometry.crown(2 * sector + 1))
                context.move(to: map(CoreGeometry.girdle(sector)))
                context.addLine(to: middle)
                context.addLine(to: map(CoreGeometry.girdle(sector + 1)))
                context.move(to: map(CoreGeometry.girdle(sector)))
                context.addLine(to: map(CoreGeometry.crown(2 * sector)))
            }
            context.strokePath()

            // 5. Dispersion: a spectral fringe inside the girdle (warm on the
            // right, cool on the left) and a few fire flecks in the crown.
            if !isVessel {
                let fringeAlpha: CGFloat = level >= 3 ? 0.50 : (level == 2 ? 0.44 : 0.38)
                context.saveGState()
                context.setBlendMode(.plusLighter)
                for sector in 0 ..< 10 {
                    let start = CoreGeometry.girdle(sector).scaled(0.955)
                    let end = CoreGeometry.girdle(sector + 1).scaled(0.955)
                    context.saveGState()
                    context.move(to: map(start))
                    context.addLine(to: map(end))
                    context.setLineWidth(radius * 0.055)
                    context.setLineCap(.round)
                    context.replacePathWithStrokedPath()
                    context.clip()
                    let startHue = CGFloat(sector) / 10
                    let endHue = CGFloat(sector + 1) / 10
                    if let fringe = gradient(
                        [
                            GemColor(hue: 0.02 + startHue * 0.78, saturation: 0.70, brightness: 1).withAlpha(fringeAlpha),
                            GemColor(hue: 0.02 + endHue * 0.78, saturation: 0.70, brightness: 1).withAlpha(fringeAlpha)
                        ],
                        [0, 1]
                    ) {
                        context.drawLinearGradient(fringe, start: map(start), end: map(end), options: [])
                    }
                    context.restoreGState()
                }
                let fire = [GemColor.fireCool, GemColor.fireWarm, GemColor.fireViolet, GemColor.fireWarm, GemColor.fireCool]
                let fleckSectors = [8, 2, 6, 4, 9, 1, 5]
                let fleckCount = Set(hexes).count == 1 ? 7 : 5
                for (index, sector) in fleckSectors.prefix(fleckCount).enumerated() {
                    let outer = CoreGeometry.girdle(sector)
                    let middle = CoreGeometry.crown(2 * sector + 1)
                    let vertex = CoreGeometry.crown(2 * sector)
                    let fleck = [
                        outer.mixed(with: middle, amount: 0.30),
                        outer.mixed(with: vertex, amount: 0.30),
                        outer.mixed(with: middle.mixed(with: vertex, amount: 0.5), amount: 0.70)
                    ]
                    context.addPath(polygon(fleck))
                    context.setFillColor(fire[index % fire.count].withAlpha(0.55).cgColor)
                    context.fillPath()
                }
                context.restoreGState()
            }

            // 6. A luminous veil from the key light (upper left), so the
            // stone glows through rather than reading as painted glass.
            context.saveGState()
            context.setBlendMode(.screen)
            if let veil = gradient(
                [UIColor(white: 1, alpha: isVessel ? 0.10 : 0.24), UIColor(white: 1, alpha: 0.06), UIColor(white: 1, alpha: 0)],
                [0, 0.55, 1]
            ) {
                let origin = map(CGPoint(x: -0.34, y: 0.40))
                context.drawRadialGradient(
                    veil,
                    startCenter: origin, startRadius: 0,
                    endCenter: origin, endRadius: radius * 1.25,
                    options: []
                )
            }
            context.restoreGState()

            // 7. Crisp specular streak at the upper left, and a glare dot.
            context.saveGState()
            context.setBlendMode(.screen)
            for (offset, length, thickness, alpha) in [
                (CGPoint(x: -0.40, y: 0.50), CGFloat(0.40), CGFloat(0.085), CGFloat(isVessel ? 0.55 : 0.95)),
                (CGPoint(x: -0.54, y: 0.28), CGFloat(0.17), CGFloat(0.045), CGFloat(isVessel ? 0.40 : 0.80))
            ] {
                guard let streak = gradient(
                    [UIColor(white: 1, alpha: alpha), UIColor(white: 1, alpha: alpha * 0.45), UIColor(white: 1, alpha: 0)],
                    [0, 0.45, 1]
                ) else { continue }
                context.saveGState()
                let point = map(offset)
                context.translateBy(x: point.x, y: point.y)
                context.rotate(by: -atan2(offset.y, offset.x) + .pi / 2)
                context.scaleBy(x: 1, y: thickness / length)
                context.drawRadialGradient(
                    streak,
                    startCenter: .zero, startRadius: 0,
                    endCenter: .zero, endRadius: radius * length,
                    options: []
                )
                context.restoreGState()
            }
            context.restoreGState()

            // 8. Bright girdle: a soft inner glow band along the outline.
            context.addPath(outline)
            context.setStrokeColor(UIColor(white: 1, alpha: isVessel ? 0.16 : 0.40).cgColor)
            context.setLineWidth(radius * 0.14)
            context.strokePath()
            context.addPath(outline)
            context.setStrokeColor(UIColor(white: 1, alpha: isVessel ? 0.34 : 0.50).cgColor)
            context.setLineWidth(radius * 0.045)
            context.strokePath()

            // 2.5 t: a crown of lights on the crown ring.
            if coreHasCrown(level: level) {
                for sector in 0 ..< 10 {
                    drawDot(context: context, center: map(CoreGeometry.crown(2 * sector)), radius: radius * 0.028, alpha: 0.95)
                }
            }
            context.restoreGState() // outline clip

            // Crisp girdle edge.
            context.setLineJoin(.round)
            context.addPath(outline)
            context.setStrokeColor(UIColor(white: 1, alpha: isVessel ? 0.62 : 0.92).cgColor)
            context.setLineWidth(max(1, radius * 0.020))
            context.strokePath()

            // White-hot star at the heart, and a small star on the left girdle.
            drawSparkle(context: context, center: map(.zero), length: radius * (isVessel ? 0.16 : 0.24), alpha: isVessel ? 0.7 : 1)
            drawSparkle(context: context, center: map(.zero), length: radius * (isVessel ? 0.09 : 0.13), alpha: 0.55, rotation: .pi / 4)
            if !isVessel {
                drawSparkle(context: context, center: map(CoreGeometry.girdle(7)), length: radius * 0.13, alpha: 0.85)
            }
        }
    }

    /// A tapered white spoke from the heart, bright at its root.
    private static func drawSpoke(
        context: CGContext,
        from start: CGPoint,
        to end: CGPoint,
        width: CGFloat,
        alphas: (CGFloat, CGFloat)
    ) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let normal = CGPoint(x: -sin(angle) * width / 2, y: cos(angle) * width / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: start.x + normal.x, y: start.y + normal.y))
        path.addLine(to: CGPoint(x: end.x + normal.x * 0.5, y: end.y + normal.y * 0.5))
        path.addLine(to: CGPoint(x: end.x - normal.x * 0.5, y: end.y - normal.y * 0.5))
        path.addLine(to: CGPoint(x: start.x - normal.x, y: start.y - normal.y))
        path.closeSubpath()
        context.saveGState()
        context.addPath(path)
        context.clip()
        let colors = [UIColor(white: 1, alpha: alphas.0).cgColor, UIColor(white: 1, alpha: alphas.1).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: start, end: end, options: [])
        }
        context.restoreGState()
    }
}

// MARK: - Tones

/// One theme colour turned into gem tones (Docs/GemExperienceDesign.md
/// §7.4). Hue is never changed: it is how people tell their themes apart.
struct GemTone: Sendable {
    let hue: CGFloat
    let saturation: CGFloat
    let brightness: CGFloat
    let lightHueShift: CGFloat
    let contrastBoost: CGFloat
    let isGlass: Bool
    let isMuted: Bool
    /// Share of white in the glint colour (white 70 % + halo 30 %; the
    /// saturated reds stay whiter so they never flash red).
    let glintWhiteShare: CGFloat

    init(hex: String, muted: Bool, glass: Bool) {
        let key = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
        let raw = GemColor(hex: key).hsb
        var saturationFloor: CGFloat = 0.74
        var brightnessFloor: CGFloat = 0.88
        var lightShift: CGFloat = 8
        var boost: CGFloat = 0
        var whiteShare: CGFloat = 0.70
        switch key {
        case "3FA57C": lightShift = -4
        case "739B45": brightnessFloor = 0.90
        case "A76A3F":
            brightnessFloor = 0.92
            boost = 0.1
        case "5688A8": saturationFloor = 0.60
        case "E85D4A", "D56B82": whiteShare = 0.85
        default: break
        }
        hue = raw.hue
        // Neutral inputs (the tutorial glass, legacy greys) stay neutral.
        let base = raw.saturation < 0.08 ? raw.saturation : max(raw.saturation, saturationFloor)
        saturation = muted ? base * 0.85 : base
        brightness = max(raw.brightness, brightnessFloor)
        lightHueShift = lightShift / 360
        contrastBoost = boost
        isGlass = glass
        isMuted = muted
        glintWhiteShare = whiteShare
    }

    var light: GemColor {
        isGlass
            ? GemColor(hex: "#EAF3FF")
            : GemColor(hue: hue + lightHueShift, saturation: min(0.30, saturation), brightness: 1)
    }

    var deep: GemColor {
        isGlass
            ? GemColor(red: 0.30, green: 0.36, blue: 0.46)
            : GemColor(hue: hue - 6 / 360, saturation: saturation < 0.08 ? saturation : 0.85, brightness: 0.44)
    }

    var halo: GemColor {
        isGlass
            ? GemColor(red: 0.78, green: 0.88, blue: 1)
            : GemColor(hue: hue, saturation: saturation < 0.08 ? saturation : (isMuted ? 0.64 : 0.75), brightness: 1)
    }

    var glint: GemColor {
        GemColor(red: 1, green: 1, blue: 1).mixed(with: halo, amount: 1 - glintWhiteShare)
    }

    /// Facet colour for facet light b (0…1): hue ± 8°. Dark facets stay
    /// deep and saturated rather than going brown, bright facets turn pale
    /// and luminous: the HSB value is 0.50 + 0.50b and saturation
    /// s₀ × (1.22 − 0.70b), so a coral gem keeps red-orange depths and
    /// near-white peach lights (luminance ratio ≈ 1:4).
    func facet(brightness b: CGFloat, hueJitter: CGFloat) -> GemColor {
        if isGlass {
            let tone = 0.45 + b * 0.55
            return GemColor(red: tone * 0.90, green: tone * 0.95, blue: tone)
        }
        let neutral = saturation < 0.08
        return GemColor(
            hue: hue + 8 / 360 * hueJitter,
            saturation: neutral ? saturation : min(1, saturation * (1.22 - 0.70 * b)),
            brightness: 0.50 + 0.50 * b
        )
    }

    var haloUIColor: UIColor { halo.withAlpha(1) }
    var glintUIColor: UIColor { glint.withAlpha(1) }
}

/// Tones by angular sector (clockwise from 12 o'clock). Colours change on
/// facet boundaries (each facet takes the tone at its centroid), so a
/// multi-theme stone reads as cut glass rather than a pie chart.
private struct SectorTones {
    private let entries: [(end: CGFloat, tone: GemTone)]
    let dominant: GemTone

    init(spec: GemArtworkSpec) {
        let glass = spec.cut == .glass
        let shares = spec.colors.filter { $0.fraction > 0 }
        let fallback = GemTone(hex: shares.first?.hex ?? "#8A9BB8", muted: spec.isMuted, glass: glass)
        dominant = fallback
        guard shares.count > 1, !glass else {
            entries = [(.pi * 2, fallback)]
            return
        }
        let total = shares.reduce(0) { $0 + $1.fraction }
        var cursor: CGFloat = 0
        var list: [(end: CGFloat, tone: GemTone)] = []
        for share in shares {
            cursor += CGFloat(share.fraction / max(total, 0.000_1)) * .pi * 2
            list.append((cursor, GemTone(hex: share.hex, muted: spec.isMuted, glass: false)))
        }
        entries = list
    }

    func tone(atAngle mathAngle: CGFloat) -> GemTone {
        guard entries.count > 1 else { return dominant }
        var clockwise = CGFloat.pi / 2 - mathAngle
        clockwise = clockwise.truncatingRemainder(dividingBy: .pi * 2)
        if clockwise < 0 { clockwise += .pi * 2 }
        return entries.first { clockwise < $0.end }?.tone ?? entries[entries.count - 1].tone
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
    /// Midpoint of white and #8ACBFF.
    static let fresnelTint = GemColor(red: 0.77, green: 0.90, blue: 1)
    static let white = GemColor(red: 1, green: 1, blue: 1)

    init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    init(_ color: UIColor) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if !color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            color.getWhite(&white, alpha: &alpha)
            red = white
            green = white
            blue = white
        }
        self.init(red: red, green: green, blue: blue)
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

    var hexString: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
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
        mixed(with: .white, amount: amount)
    }

    func darker(_ amount: CGFloat) -> GemColor {
        GemColor(red: red * (1 - amount), green: green * (1 - amount), blue: blue * (1 - amount))
    }

    /// Rec. 709 relative luminance of the (gamma-encoded) value, for tests.
    var luminance: CGFloat {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
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

    /// Additive halo colour: the theme hue at s0.75, b1.0 (never white).
    func haloColor(muted: Bool) -> UIColor {
        GemTone(hex: hexString, muted: muted, glass: false).haloUIColor
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
    /// variety (facet variant, glint position and phase, twinkle order).
    var presentationHash: UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in uuidString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

private extension CGPoint {
    func scaled(_ factor: CGFloat) -> CGPoint {
        CGPoint(x: x * factor, y: y * factor)
    }

    func mixed(with other: CGPoint, amount: CGFloat) -> CGPoint {
        CGPoint(x: x + (other.x - x) * amount, y: y + (other.y - y) * amount)
    }
}
