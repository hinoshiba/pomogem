import SpriteKit
import XCTest
@testable import PomoGem

/// Themes told apart without relying on hue alone: the lightness-order gem
/// tone transform over the theme palette, the Differentiate Without Color
/// marks, and the same object drawn in the same colours on Home, the
/// Overview and share cards (Docs/GemExperienceDesign.md §7.4, §7.12, §8.5).
///
/// Every palette test reads `SubjectPalette` itself, never a copy of its
/// hex list, so a curated palette is checked automatically.
final class GemThemeDistinctionTests: XCTestCase {
    private var palette: [String] { SubjectPalette.hexes }

    // MARK: Lightness order (the brightness-order render transform)

    func testPaletteIsOneListOfDistinctColours() {
        XCTAssertGreaterThanOrEqual(palette.count, 2)
        XCTAssertEqual(Set(palette.map(SubjectPalette.normalized)).count, palette.count, "No swatch twice")
        for (index, hex) in palette.enumerated() {
            XCTAssertEqual(SubjectPalette.index(of: hex), index)
            XCTAssertEqual(SubjectPalette.index(of: hex.lowercased().replacingOccurrences(of: "#", with: "")), index)
        }
        XCTAssertNil(SubjectPalette.index(of: "#010203"))
    }

    /// A lighter swatch always makes a lighter gem (OKLab L of the body
    /// colour), for measured and self-reported gems alike.
    func testGemTonesKeepThePalettesLightnessOrder() {
        for muted in [false, true] {
            let pairs = palette.map { hex in
                (
                    hex: hex,
                    input: GemColor(hex: hex).oklabLightness,
                    output: GemTone(hex: hex, muted: muted, glass: false).body.oklabLightness
                )
            }
            for a in pairs {
                for b in pairs where a.hex != b.hex && a.input < b.input - 0.001 {
                    XCTAssertLessThan(
                        a.output, b.output,
                        "\(a.hex) (L \(a.input)) must stay darker than \(b.hex) (L \(b.input)) in the jar (muted: \(muted))"
                    )
                }
            }
        }
    }

    /// The body colour is exactly the facet at the reference light, so the
    /// order holds for the colour every facet ramp is built around.
    func testBodyColourIsTheReferenceFacet() {
        for hex in palette {
            let tone = GemTone(hex: hex, muted: false, glass: false)
            let facet = tone.facet(brightness: GemTone.referenceFacetLight, hueJitter: 0)
            XCTAssertEqual(facet.red, tone.body.red, accuracy: 0.002, hex)
            XCTAssertEqual(facet.green, tone.body.green, accuracy: 0.002, hex)
            XCTAssertEqual(facet.blue, tone.body.blue, accuracy: 0.002, hex)
            XCTAssertEqual(
                tone.body.oklabLightness,
                GemToneLightness.bodyLightness(forInput: GemColor(hex: hex).oklabLightness),
                accuracy: 0.003,
                "\(hex) reaches its lightness (a hue too dark at the vivid saturation gives way toward white)"
            )
        }
    }

    /// The curve is strictly increasing and bounded for any colour, and
    /// widens (never narrows) the lightness steps where themes live.
    func testLightnessCurveIsStrictlyIncreasingAndWidensPaletteSteps() {
        var previous = -CGFloat.greatestFiniteMagnitude
        for step in 0 ... 200 {
            let value = GemToneLightness.bodyLightness(forInput: CGFloat(step) / 200)
            XCTAssertGreaterThan(value, previous)
            XCTAssertGreaterThanOrEqual(value, GemToneLightness.outputCenter - GemToneLightness.amplitude)
            XCTAssertLessThanOrEqual(value, GemToneLightness.outputCenter + GemToneLightness.amplitude)
            previous = value
        }
        let lightness = palette.map { GemColor(hex: $0).oklabLightness }
        for a in lightness {
            for b in lightness where b > a + 0.001 && a > 0.50 && b < 0.76 {
                let widened = GemToneLightness.bodyLightness(forInput: b) - GemToneLightness.bodyLightness(forInput: a)
                XCTAssertGreaterThanOrEqual(widened, (b - a) * 0.98)
            }
        }
    }

    /// Baked gems (facets, inner light, edges) keep the order too, for
    /// every pair of swatches at least 0.02 apart in lightness.
    func testRenderedGemsKeepThePalettesLightnessOrder() throws {
        let rendered = try palette.map { hex -> (hex: String, input: CGFloat, output: CGFloat) in
            let spec = GemArtworkSpec(
                rung: GemCutLadder.standard.loose,
                colors: [GemColorShare(hex: hex, fraction: 1)],
                variant: 0,
                isMuted: false,
                showsDashedRing: false
            )
            let image = GemArtwork.renderBodyImage(for: spec, radius: 24, scale: 2)
            return (hex, GemColor(hex: hex).oklabLightness, try meanOKLabLightness(of: image))
        }
        for a in rendered {
            for b in rendered where a.input < b.input - 0.02 {
                XCTAssertLessThan(a.output, b.output, "\(a.hex) → \(a.output), \(b.hex) → \(b.output)")
            }
        }
    }

    // MARK: Differentiate Without Color marks

    func testEveryPaletteThemeHasItsOwnMark() {
        let marks = palette.map(GemThemeMark.init(hex:))
        XCTAssertEqual(Set(marks).count, marks.count, "One distinct mark per swatch")
        for (index, mark) in marks.enumerated() where index < GemThemeMark.Glyph.allCases.count {
            XCTAssertFalse(mark.isFramed, "A palette theme wears a plain glyph")
            XCTAssertEqual(mark.glyph, GemThemeMark.Glyph.allCases[index], "Keyed by palette index")
        }
        // Colours outside the palette are framed, so they never pass for a
        // palette theme; the legacy hue-rotation colours spread by hue.
        let legacy = (0 ..< 12).map { step in
            GemColor(hue: CGFloat(step) / 12, saturation: 0.62, brightness: 0.82).hexString
        }.filter { SubjectPalette.index(of: $0) == nil }
        let legacyMarks = legacy.map(GemThemeMark.init(hex:))
        XCTAssertTrue(legacyMarks.allSatisfy(\.isFramed))
        XCTAssertEqual(Set(legacyMarks).count, legacyMarks.count)
        XCTAssertTrue(Set(legacyMarks).isDisjoint(with: Set(marks)))
        XCTAssertEqual(GemThemeMark(hex: "#8B93AC"), GemThemeMark(hex: "8b93ac"), "Stable per colour")
    }

    func testMarksAreOffByDefaultAndLeaveTheDefaultBakeUntouched() {
        let spec = GemArtworkSpec(
            rung: GemCutLadder.standard.loose,
            colors: [GemColorShare(hex: Constants.Color.english, fraction: 1)],
            variant: 1,
            isMuted: false,
            showsDashedRing: false
        )
        XCTAssertFalse(spec.showsThemeMarks)
        XCTAssertFalse(spec.cacheKey.hasSuffix("|t"))
        XCTAssertEqual(spec.withThemeMarks(true).withThemeMarks(false), spec)
        XCTAssertEqual(spec.withThemeMarks(false).cacheKey, spec.cacheKey)
        XCTAssertNotEqual(spec.withThemeMarks(true).cacheKey, spec.cacheKey)
        XCTAssertEqual(spec.withThemeMarks(true).withVariant(2).showsThemeMarks, true)

        let shares = [GemColorShare(hex: Constants.Color.english, fraction: 1)]
        XCTAssertEqual(
            GemArtwork.coreImageKey(shares: shares, level: 1, scale: 3),
            GemArtwork.coreImageKey(shares: shares, level: 1, scale: 3, themeMarks: false)
        )
        XCTAssertNotEqual(
            GemArtwork.coreImageKey(shares: shares, level: 1, scale: 3),
            GemArtwork.coreImageKey(shares: shares, level: 1, scale: 3, themeMarks: true)
        )
    }

    /// The engraving shows on the palest and on the darkest swatch: a deep
    /// cut on the table with a lit rim, and nothing changes off the table.
    func testMarkedGemsCarryAVisibleEngraving() throws {
        let lightness = palette.map { ($0, GemColor(hex: $0).oklabLightness) }
        let extremes = [lightness.min { $0.1 < $1.1 }!.0, lightness.max { $0.1 < $1.1 }!.0]
        for hex in extremes {
            let spec = GemArtworkSpec(
                rung: GemCutLadder.standard.loose,
                colors: [GemColorShare(hex: hex, fraction: 1)],
                variant: 0,
                isMuted: false,
                showsDashedRing: false
            )
            // A 20 pt gem, as small as a share card or the Overview shows one.
            let plain = try pixels(of: GemArtwork.renderBodyImage(for: spec, radius: 10, scale: 3))
            let marked = try pixels(of: GemArtwork.renderBodyImage(for: spec.withThemeMarks(true), radius: 10, scale: 3))
            let table = plain.region(radiusFraction: 0 ... 0.36)
            let markedTable = marked.region(radiusFraction: 0 ... 0.36)
            let rim = plain.region(radiusFraction: 0.62 ... 0.90)
            let markedRim = marked.region(radiusFraction: 0.62 ... 0.90)
            XCTAssertLessThan(markedTable.minimumLuminance, table.minimumLuminance - 0.25, "\(hex): a deep cut")
            XCTAssertGreaterThan(markedTable.darkShare, 0.12, "\(hex): the glyph covers part of the table")
            XCTAssertEqual(markedRim.meanLuminance, rim.meanLuminance, accuracy: 0.01, "\(hex): off the table the gem is unchanged")
        }
    }

    /// Glyphs are legible at 20 pt: an 8 pt glyph on a single-theme gem,
    /// and every glyph fills its circle without leaving it.
    func testGlyphsAreLegibleAtTwentyPoints() {
        let single = GemArtwork.themeMarkPlacements(for: [GemColorShare(hex: palette[0], fraction: 1)])
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].center, .zero)
        XCTAssertGreaterThanOrEqual(single[0].radius * 10 * 2, 8, "8 pt glyph on a 20 pt gem")
        // A crystal of several themes that small shows its largest theme's
        // mark on the table rather than four specks.
        let mix = [
            GemColorShare(hex: palette[1 % palette.count], fraction: 0.3),
            GemColorShare(hex: palette[0], fraction: 0.5),
            GemColorShare(hex: palette[2 % palette.count], fraction: 0.2)
        ]
        let small = GemArtwork.themeMarkPlacements(for: mix, radius: 10)
        XCTAssertEqual(small.map(\.mark), [GemThemeMark(hex: palette[0])])
        XCTAssertGreaterThanOrEqual(small[0].radius * 10 * 2, 8)
        for radius: CGFloat in [16, 24, 40] {
            let placements = GemArtwork.themeMarkPlacements(for: mix, radius: radius)
            XCTAssertEqual(placements.count, 3)
            XCTAssertTrue(placements.allSatisfy { $0.radius * radius * 2 >= GemArtwork.minimumThemeMarkGlyphSize })
        }
        for glyph in GemThemeMark.Glyph.allCases {
            for framed in [false, true] {
                let box = GemArtwork.themeMarkPath(
                    GemThemeMark(glyph: glyph, isFramed: framed),
                    center: .zero,
                    radius: 1
                ).boundingBoxOfPath
                XCTAssertGreaterThanOrEqual(box.minX, -1.001, "\(glyph)")
                XCTAssertLessThanOrEqual(box.maxX, 1.001, "\(glyph)")
                XCTAssertGreaterThanOrEqual(box.minY, -1.001, "\(glyph)")
                XCTAssertLessThanOrEqual(box.maxY, 1.001, "\(glyph)")
                XCTAssertGreaterThan(max(box.width, box.height), 1.0, "\(glyph) is not a speck")
            }
        }
    }

    /// A crystal of several themes carries each theme's mark inside that
    /// theme's own sector, fully inside the stone.
    func testCrystalMarksSitInTheirOwnSectors() {
        let shares = [
            GemColorShare(hex: palette[0], fraction: 0.5),
            GemColorShare(hex: palette[1 % palette.count], fraction: 0.3),
            GemColorShare(hex: palette[2 % palette.count], fraction: 0.2)
        ]
        let placements = GemArtwork.themeMarkPlacements(for: shares)
        XCTAssertEqual(placements.map(\.mark), shares.map { GemThemeMark(hex: $0.hex) })
        var start: CGFloat = 0
        for (placement, share) in zip(placements, shares) {
            let end = start + CGFloat(share.fraction)
            // Clockwise turn from 12 o'clock of the mark's centre.
            var turn = (CGFloat.pi / 2 - atan2(placement.center.y, placement.center.x)) / (.pi * 2)
            if turn < 0 { turn += 1 }
            XCTAssertGreaterThan(turn, start)
            XCTAssertLessThan(turn, end)
            XCTAssertLessThanOrEqual(hypot(placement.center.x, placement.center.y) + placement.radius, 0.85)
            start = end
        }
    }

    /// The core marks every theme arc but not the mixed その他 arc.
    func testCoreMarksEveryThemeArcButNotTheMixedRest() {
        let themes = (0 ..< min(7, palette.count)).map { palette[$0] }
        let fractions: [Double] = [0.30, 0.22, 0.16, 0.12, 0.10, 0.06, 0.04]
        let shares = zip(themes, fractions).map { GemColorShare(hex: $0.0, fraction: $0.1) }
        let placements = GemArtwork.coreThemeMarkPlacements(shares: shares)
        let quantized = GemArtwork.quantizedCoreShares(shares)
        let expected = quantized.filter { share in themes.contains { SubjectPalette.normalized($0) == SubjectPalette.normalized(share.hex) } }
        XCTAssertEqual(placements.count, expected.count)
        XCTAssertLessThan(placements.count, quantized.count, "その他 carries no mark")
        XCTAssertEqual(Set(placements.map(\.mark)).count, placements.count)
        let single = GemArtwork.coreThemeMarkPlacements(shares: [GemColorShare(hex: palette[0], fraction: 1)])
        XCTAssertEqual(single.map(\.mark), [GemThemeMark(hex: palette[0])])
    }

    @MainActor
    func testTheJarTogglesMarksOnStudyGemsOnly() {
        let scene = JarScene(size: CGSize(width: 390, height: Constants.Jar.height))
        scene.soundEnabled = false
        scene.hapticsEnabled = false
        scene.reduceMotion = true
        scene.bakesGemBedInBackground = false
        let loose = PebbleDescriptor(
            id: UUID(uuidString: "D0C00000-0000-4000-8000-000000000001")!,
            subjectName: "英語",
            colorHex: palette[0],
            source: .timer,
            kind: .normal,
            grams: Constants.Mass.measuredPebbleGrams
        )
        let crystal = PebbleDescriptor(
            id: UUID(uuidString: "D0C00000-0000-4000-8000-000000000002")!,
            subjectName: "英語",
            colorHex: palette[0],
            source: .timer,
            kind: .normal,
            aggregate: AggregateMetadata(
                level: 1,
                pebbleCount: 10,
                childAggregateCount: 0,
                colorMix: [StratumColorFraction(hex: palette[0], fraction: 1)],
                subjectMix: [],
                periodStart: Date(timeIntervalSince1970: 100),
                periodEnd: Date(timeIntervalSince1970: 200),
                sessionIDs: [],
                measuredPebbleCount: 10,
                manualPebbleCount: 0,
                goldPebbleCount: 0,
                prismPebbleCount: 0
            ),
            grams: 10 * Constants.Mass.measuredPebbleGrams
        )
        let stone = PebbleDescriptor(
            id: UUID(uuidString: "D0C00000-0000-4000-8000-000000000003")!,
            subjectName: "資格",
            colorHex: palette[0],
            source: .manual,
            kind: .normal,
            achievementKind: .examPass,
            grams: 0
        )
        scene.restore(pebbles: [loose, crystal, stone])
        let pebbles = scene.children.flatMap(\.children).compactMap { $0 as? PebbleNode }
        XCTAssertEqual(pebbles.count, 3)
        scene.setThemeMarks(true)
        for pebble in pebbles {
            XCTAssertEqual(pebble.displayedBodySpec?.showsThemeMarks, !pebble.descriptor.isAchievement, pebble.descriptor.subjectName)
        }
        scene.setThemeMarks(false)
        XCTAssertTrue(pebbles.allSatisfy { $0.displayedBodySpec?.showsThemeMarks != true })

        // The launch and restore pre-bakes follow the same rule.
        XCTAssertEqual(PebbleNode.bodySpec(for: loose, themeMarks: true)?.showsThemeMarks, true)
        XCTAssertEqual(PebbleNode.bodySpec(for: crystal, themeMarks: true)?.showsThemeMarks, true)
        XCTAssertEqual(PebbleNode.bodySpec(for: stone, themeMarks: true)?.showsThemeMarks, false)
        let tutorial = PebbleDescriptor(
            subjectName: "",
            colorHex: palette[0],
            source: .timer,
            kind: .normal,
            grams: 0,
            isTutorial: true
        )
        XCTAssertEqual(PebbleNode.bodySpec(for: tutorial, themeMarks: true)?.showsThemeMarks, false)
    }

    // MARK: One object, one colour set (Home, Overview, share)

    /// Home and the Overview read the time core's fan from one function:
    /// root crystals by their colour mix plus loose gems.
    func testTimeCoreFanIsOneFunctionOfRootsAndLooseGems() {
        let coral = palette[0]
        let blue = palette[1 % palette.count]
        let shares = JarLifetimeCorePresentation.colorShares([
            JarLifetimeCorePresentation.ColorContribution(
                grams: 2_500,
                colorMix: [StratumColorFraction(hex: coral, fraction: 0.6), StratumColorFraction(hex: blue, fraction: 0.4)]
            ),
            JarLifetimeCorePresentation.ColorContribution(grams: 250, hex: blue),
            JarLifetimeCorePresentation.ColorContribution(grams: 250, hex: coral)
        ])
        XCTAssertEqual(shares.map(\.hex), [coral, blue])
        XCTAssertEqual(shares[0].fraction, 1_750.0 / 3_000.0, accuracy: 0.000_1)
        XCTAssertEqual(shares[1].fraction, 1_250.0 / 3_000.0, accuracy: 0.000_1)
        XCTAssertTrue(JarLifetimeCorePresentation.colorShares([]).isEmpty)
        XCTAssertTrue(JarLifetimeCorePresentation.colorShares([
            JarLifetimeCorePresentation.ColorContribution(grams: 0, hex: coral)
        ]).isEmpty)
    }

    /// The fusion sheet's ten sources show the crystal's own themes in
    /// proportion, and its destination the crystal's colour mix.
    func testFusionSourcesShowTheCrystalsOwnThemes() {
        let coral = palette[0]
        let blue = palette[1 % palette.count]
        let violet = palette[4 % palette.count]
        let sources = FusionOrbitStage.sourceHexes(
            shares: [
                GemColorShare(hex: coral, fraction: 0.52),
                GemColorShare(hex: blue, fraction: 0.29),
                GemColorShare(hex: violet, fraction: 0.19)
            ],
            count: 10
        )
        XCTAssertEqual(sources.count, 10)
        XCTAssertEqual(sources.filter { $0 == coral }.count, 5)
        XCTAssertEqual(sources.filter { $0 == blue }.count, 3)
        XCTAssertEqual(sources.filter { $0 == violet }.count, 2)
        XCTAssertEqual(FusionOrbitStage.sourceHexes(shares: [GemColorShare(hex: coral, fraction: 1)], count: 10), Array(repeating: coral, count: 10))
        XCTAssertTrue(FusionOrbitStage.sourceHexes(shares: [], count: 10).isEmpty)
    }

    // MARK: Core labels on a shortened stage

    /// Whatever the stage height, the label block never reaches the pile:
    /// the second line gives way first, then the whole block.
    func testCoreLabelsGiveWayOnAShortenedStage() throws {
        let state = try XCTUnwrap(JarLifetimeCorePresentation.state(
            totalPebbleCount: 15,
            totalGrams: 3_750,
            projectionIsLowerBound: false,
            effortSnapshot: JarAccumulationPresencePresentation.effortSnapshot(totalGrams: 3_750)
        ))
        XCTAssertNotNil(state.nextFusionLabel)
        let width: CGFloat = 390
        func layout(stage: CGFloat, limit: CGFloat) -> (CGFloat) -> JarLifetimeCoreLayout {
            { height in
                JarLifetimeCoreLabels.layout(
                    stageSize: CGSize(width: width, height: stage),
                    state: state,
                    topClearance: 90,
                    bottomLimit: stage - 60,
                    labelBottomLimit: limit,
                    labelHeight: height
                )
            }
        }
        let full: CGFloat = 56
        let second: CGFloat = 12
        // A tall stage with a low pile: everything shows.
        XCTAssertEqual(
            JarLifetimeCoreLabelFit.resolve(fullHeight: full, secondLineHeight: second, abovePileLimit: 400, layout: layout(stage: 470, limit: 400)),
            .full
        )
        // Shortened by the completion card: scan the pile top upward and
        // check that whatever shows stays above it.
        let stage: CGFloat = 360
        var sawCompact = false
        var sawHidden = false
        for limit in stride(from: CGFloat(300), through: 120, by: -2) {
            let fit = JarLifetimeCoreLabelFit.resolve(
                fullHeight: full,
                secondLineHeight: second,
                abovePileLimit: limit,
                layout: layout(stage: stage, limit: limit)
            )
            switch fit {
            case .full, .withoutSecondLine:
                let height = fit.labelHeight(full: full, secondLine: second)
                let resolved = layout(stage: stage, limit: limit)(height)
                XCTAssertLessThanOrEqual(resolved.labelTop + height, limit + 0.5, "limit \(limit)")
                XCTAssertFalse(resolved.overflows)
                if fit == .withoutSecondLine { sawCompact = true }
            case .hidden:
                sawHidden = true
            }
        }
        XCTAssertTrue(sawCompact, "The second line gives way before the block hides")
        XCTAssertTrue(sawHidden)
        // Without a second line there is nothing to drop.
        XCTAssertNotEqual(
            JarLifetimeCoreLabelFit.resolve(fullHeight: full, secondLineHeight: 0, abovePileLimit: 150, layout: layout(stage: stage, limit: 150)),
            .withoutSecondLine
        )
    }

    // MARK: Pixel helpers

    private struct Pixels {
        let width: Int
        let height: Int
        let data: [UInt8]

        struct Region {
            let minimumLuminance: CGFloat
            let meanLuminance: CGFloat
            /// Share of opaque pixels darker than luminance 0.25.
            let darkShare: CGFloat
        }

        func region(radiusFraction range: ClosedRange<CGFloat>) -> Region {
            let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
            // Bodies are baked with a margin; the stone fills about 0.87 of
            // the half side at radius 10 (1.5 pt margin).
            let radius = CGFloat(min(width, height)) / 2 / 1.15
            var minimum: CGFloat = 1
            var total: CGFloat = 0
            var count: CGFloat = 0
            var dark: CGFloat = 0
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let distance = hypot(CGFloat(x) + 0.5 - center.x, CGFloat(y) + 0.5 - center.y) / radius
                    guard range.contains(distance) else { continue }
                    let offset = (y * width + x) * 4
                    let alpha = CGFloat(data[offset + 3])
                    guard alpha > 200 else { continue }
                    let luminance = (0.2126 * CGFloat(data[offset]) + 0.7152 * CGFloat(data[offset + 1]) + 0.0722 * CGFloat(data[offset + 2])) / alpha
                    minimum = min(minimum, luminance)
                    total += luminance
                    count += 1
                    if luminance < 0.25 { dark += 1 }
                }
            }
            return Region(
                minimumLuminance: minimum,
                meanLuminance: count > 0 ? total / count : 0,
                darkShare: count > 0 ? dark / count : 0
            )
        }
    }

    private func pixels(of image: UIImage) throws -> Pixels {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Pixels(width: width, height: height, data: data)
    }

    /// Mean OKLab lightness of the opaque pixels (straight colour).
    private func meanOKLabLightness(of image: UIImage) throws -> CGFloat {
        let image = try pixels(of: image)
        var total: CGFloat = 0
        var count: CGFloat = 0
        for index in stride(from: 0, to: image.data.count, by: 4) where image.data[index + 3] > 200 {
            let alpha = CGFloat(image.data[index + 3])
            let color = GemColor(
                red: CGFloat(image.data[index]) / alpha,
                green: CGFloat(image.data[index + 1]) / alpha,
                blue: CGFloat(image.data[index + 2]) / alpha
            )
            total += color.oklabLightness
            count += 1
        }
        return count > 0 ? total / count : 0
    }
}
