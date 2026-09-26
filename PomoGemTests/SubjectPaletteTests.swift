import XCTest
@testable import PomoGem

/// a11y-04: one palette for onboarding and Settings, and a new theme always
/// starts on a swatch no theme uses yet, in an order that stays
/// distinguishable for people with red-green colour-vision deficiency.
final class SubjectPaletteTests: XCTestCase {
    func testThePaletteHasOneUniqueSwatchPerThemeSlot() {
        let keys = SubjectPalette.hexes.map(SubjectPalette.normalized)
        XCTAssertEqual(keys.count, Constants.App.maximumSubjects)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertEqual(Set(SubjectPalette.swatches.map(\.name)).count, keys.count)
        for key in keys {
            XCTAssertNotNil(UInt32(key, radix: 16), key)
            XCTAssertEqual(key.count, 6, key)
        }
    }

    func testThePresetThemeColoursAreSwatches() {
        for preset in SeedData.subjects {
            XCTAssertTrue(SubjectPalette.contains(preset.colorHex), preset.name)
        }
        // The learning and work suggestions onboarding offers keep their
        // colours, so every one of them must open the editor on a swatch.
        for preset in SubjectSuggestionCatalog.presets {
            XCTAssertTrue(SubjectPalette.contains(preset.colorHex), preset.name)
        }
    }

    func testAFirstThemeStartsOnTheFirstSwatch() {
        XCTAssertEqual(SubjectPalette.suggestedHex(existing: []), SubjectPalette.hexes[0])
    }

    func testTheSuggestionSkipsColoursInUseWhateverTheirSpelling() {
        let first = SubjectPalette.hexes[0]
        let second = SubjectPalette.hexes[1]
        XCTAssertEqual(
            SubjectPalette.suggestedHex(existing: [first.lowercased(), String(second.dropFirst())]),
            SubjectPalette.hexes[2]
        )
    }

    func testTheSuggestionIsAlwaysAnUnusedSwatchUntilAllAreTaken() {
        var used: [String] = []
        for _ in SubjectPalette.swatches {
            let suggestion = SubjectPalette.suggestedHex(existing: used)
            XCTAssertTrue(SubjectPalette.contains(suggestion))
            XCTAssertFalse(
                used.contains { SubjectPalette.normalized($0) == SubjectPalette.normalized(suggestion) },
                "\(suggestion) is already used by \(used)"
            )
            used.append(suggestion)
        }
        XCTAssertEqual(used, SubjectPalette.hexes, "Suggestions follow the palette order")
    }

    func testColoursOutsideThePaletteTakeNoSwatch() {
        // 1.0.x suggested HSB hue steps such as these for new themes.
        let legacy = ["#CC4E4E", "#CC8D4E", "#CCCC4E"]
        XCTAssertEqual(SubjectPalette.suggestedHex(existing: legacy), SubjectPalette.hexes[0])
        XCTAssertFalse(legacy.contains(where: SubjectPalette.contains))
    }

    func testOnceEverySwatchIsUsedTheLeastUsedOneComesBackDeterministically() {
        let all = SubjectPalette.hexes
        XCTAssertEqual(SubjectPalette.suggestedHex(existing: all), all[0])
        XCTAssertEqual(SubjectPalette.suggestedHex(existing: all + [all[0], all[1]]), all[2])
        XCTAssertEqual(
            SubjectPalette.suggestedHex(existing: all + all),
            SubjectPalette.suggestedHex(existing: all + all)
        )
    }

    /// The list order is the suggestion order: each swatch is the one farthest
    /// (CIEDE2000) from every swatch before it, taking the worst of normal
    /// vision, deuteranopia and protanopia. The first themes a person adds are
    /// therefore the easiest to tell apart for everyone.
    func testThePaletteIsInColourVisionSpreadOrder() {
        let colours = SubjectPalette.hexes.map(PaletteVision.init(hex:))
        for position in 1 ..< colours.count {
            let earlier = colours[..<position]
            let spread = { (candidate: PaletteVision) in
                earlier.map { candidate.worstCaseDistance(to: $0) }.min() ?? 0
            }
            let chosen = spread(colours[position])
            let best = colours[position...].map(spread).max() ?? 0
            XCTAssertEqual(
                chosen,
                best,
                accuracy: 0.001,
                "\(SubjectPalette.swatches[position].name) is not the farthest remaining swatch"
            )
        }
        // The two most likely first themes stay far apart under every vision.
        XCTAssertGreaterThan(colours[0].worstCaseDistance(to: colours[1]), 40)
    }
}

/// sRGB → CIELAB for normal vision and for Machado et al. (2009) severity-1
/// deuteranopia and protanopia, compared with CIEDE2000.
private struct PaletteVision {
    let normal: [Double]
    let deutan: [Double]
    let protan: [Double]

    init(hex: String) {
        let value = UInt32(SubjectPalette.normalized(hex), radix: 16) ?? 0
        let srgb = [
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        ]
        let linear = srgb.map(Self.linearized)
        normal = Self.lab(linear: linear)
        deutan = Self.lab(linear: Self.simulated(linear, Self.deuteranopia))
        protan = Self.lab(linear: Self.simulated(linear, Self.protanopia))
    }

    func worstCaseDistance(to other: PaletteVision) -> Double {
        min(
            Self.ciede2000(normal, other.normal),
            Self.ciede2000(deutan, other.deutan),
            Self.ciede2000(protan, other.protan)
        )
    }

    private static let deuteranopia: [[Double]] = [
        [0.367322, 0.860646, -0.227968],
        [0.280085, 0.672501, 0.047413],
        [-0.011820, 0.042940, 0.968881]
    ]
    private static let protanopia: [[Double]] = [
        [0.152286, 1.052583, -0.204868],
        [0.114503, 0.786281, 0.099216],
        [-0.003882, -0.048116, 1.051998]
    ]

    private static func linearized(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// The simulation leaves the gamut slightly; clamp as the display would.
    private static func simulated(_ linear: [Double], _ matrix: [[Double]]) -> [Double] {
        matrix.map { row in
            let value = zip(row, linear).map(*).reduce(0, +)
            let encoded = value <= 0.0031308
                ? 12.92 * value
                : 1.055 * pow(max(value, 0), 1 / 2.4) - 0.055
            return linearized(min(max(encoded, 0), 1))
        }
    }

    private static func lab(linear: [Double]) -> [Double] {
        let x = (0.4124 * linear[0] + 0.3576 * linear[1] + 0.1805 * linear[2]) / 0.95047
        let y = 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        let z = (0.0193 * linear[0] + 0.1192 * linear[1] + 0.9505 * linear[2]) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0 }
        return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))]
    }

    private static func ciede2000(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let (l1, a1, b1) = (lhs[0], lhs[1], lhs[2])
        let (l2, a2, b2) = (rhs[0], rhs[1], rhs[2])
        let meanC = (hypot(a1, b1) + hypot(a2, b2)) / 2
        let g = 0.5 * (1 - sqrt(pow(meanC, 7) / (pow(meanC, 7) + pow(25, 7))))
        let a1p = (1 + g) * a1
        let a2p = (1 + g) * a2
        let c1p = hypot(a1p, b1)
        let c2p = hypot(a2p, b2)
        func hue(_ b: Double, _ a: Double) -> Double {
            let degrees = atan2(b, a) * 180 / .pi
            return degrees < 0 ? degrees + 360 : degrees
        }
        let h1p = hue(b1, a1p)
        let h2p = hue(b2, a2p)
        let deltaLp = l2 - l1
        let deltaCp = c2p - c1p
        var deltahp = 0.0
        if c1p * c2p != 0 {
            deltahp = h2p - h1p
            if deltahp > 180 { deltahp -= 360 } else if deltahp < -180 { deltahp += 360 }
        }
        let deltaHp = 2 * sqrt(c1p * c2p) * sin(deltahp * .pi / 360)
        let meanLp = (l1 + l2) / 2
        let meanCp = (c1p + c2p) / 2
        var meanhp = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) <= 180 {
                meanhp = (h1p + h2p) / 2
            } else if h1p + h2p < 360 {
                meanhp = (h1p + h2p + 360) / 2
            } else {
                meanhp = (h1p + h2p - 360) / 2
            }
        }
        func cosd(_ degrees: Double) -> Double { cos(degrees * .pi / 180) }
        let t = 1 - 0.17 * cosd(meanhp - 30) + 0.24 * cosd(2 * meanhp)
            + 0.32 * cosd(3 * meanhp + 6) - 0.20 * cosd(4 * meanhp - 63)
        let deltaTheta = 30 * exp(-pow((meanhp - 275) / 25, 2))
        let rc = 2 * sqrt(pow(meanCp, 7) / (pow(meanCp, 7) + pow(25, 7)))
        let sl = 1 + 0.015 * pow(meanLp - 50, 2) / sqrt(20 + pow(meanLp - 50, 2))
        let sc = 1 + 0.045 * meanCp
        let sh = 1 + 0.015 * meanCp * t
        let rt = -sin(2 * deltaTheta * .pi / 180) * rc
        let lTerm = deltaLp / sl
        let cTerm = deltaCp / sc
        let hTerm = deltaHp / sh
        return sqrt(lTerm * lTerm + cTerm * cTerm + hTerm * hTerm + rt * cTerm * hTerm)
    }
}
