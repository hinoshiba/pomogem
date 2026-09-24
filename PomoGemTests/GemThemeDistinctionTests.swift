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
