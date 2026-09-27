import Foundation

/// The theme colour palette: the one ordered list of swatches that theme
/// setup offers (onboarding and the theme editor). Keep it the only list of
/// theme hexes, so curating it changes every surface that reads it at once.
///
/// The order is the suggestion order (a11y-04). A new theme starts on the
/// first swatch no theme uses yet, and the list is ordered so that every
/// prefix stays as far apart as the palette allows under normal vision and
/// under simulated deuteranopia and protanopia (greedy farthest-point by
/// CIEDE2000, Machado 2009 matrices): 朱色 and 瑠璃 first, 若草 last because
/// it is closest to 琥珀. `SubjectPaletteTests` checks the order.
///
/// Stored theme colours are never rewritten from here: a theme keeps the
/// hex it was saved with, and a hex that is not (or no longer) in the list
/// simply has no palette index. The theme editor shows such a colour as
/// 「現在の色」.
enum SubjectPalette {
    struct Swatch: Hashable, Sendable {
        let hex: String
        let name: String
    }

    static let swatches: [Swatch] = [
        Swatch(hex: Constants.Color.english, name: String(localized: "朱色", table: "Settings", comment: "Theme colour swatch (vermilion)")),
        Swatch(hex: Constants.Color.mathematics, name: String(localized: "瑠璃", table: "Settings", comment: "Theme colour swatch (lapis blue)")),
        Swatch(hex: "#36A7AE", name: String(localized: "青緑", table: "Settings", comment: "Theme colour swatch (teal)")),
        Swatch(hex: Constants.Color.science, name: String(localized: "緑青", table: "Settings", comment: "Theme colour swatch (verdigris green)")),
        Swatch(hex: "#5688A8", name: String(localized: "空色", table: "Settings", comment: "Theme colour swatch (sky blue)")),
        Swatch(hex: "#5967C8", name: String(localized: "藍", table: "Settings", comment: "Theme colour swatch (indigo)")),
        Swatch(hex: "#D6863A", name: String(localized: "琥珀", table: "Settings", comment: "Theme colour swatch (amber)")),
        Swatch(hex: Constants.Color.japanese, name: String(localized: "紅藤", table: "Settings", comment: "Theme colour swatch (orchid)")),
        Swatch(hex: "#A76A3F", name: String(localized: "赤銅", table: "Settings", comment: "Theme colour swatch (copper)")),
        Swatch(hex: Constants.Color.socialStudies, name: String(localized: "菫", table: "Settings", comment: "Theme colour swatch (violet)")),
        Swatch(hex: "#D56B82", name: String(localized: "珊瑚", table: "Settings", comment: "Theme colour swatch (coral)")),
        Swatch(hex: "#739B45", name: String(localized: "若草", table: "Settings", comment: "Theme colour swatch (fresh green)"))
    ]

    static var hexes: [String] { swatches.map(\.hex) }

    /// Position of `hex` in the palette (case- and `#`-insensitive), or nil
    /// for a colour outside it.
    static func index(of hex: String) -> Int? {
        let key = normalized(hex)
        return swatches.firstIndex { normalized($0.hex) == key }
    }

    static func contains(_ hex: String) -> Bool {
        index(of: hex) != nil
    }

    static func normalized(_ hex: String) -> String {
        hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
    }

    /// The colour a new theme starts with: the first swatch that none of
    /// `existing` uses. Pass every theme that still has gems in the jar,
    /// archived ones included. Once all twelve are taken, the least-used
    /// swatch, the earliest on a tie. Colours outside the palette take no
    /// swatch.
    static func suggestedHex(existing: [String]) -> String {
        var uses = Array(repeating: 0, count: swatches.count)
        for hex in existing {
            if let index = index(of: hex) {
                uses[index] += 1
            }
        }
        let fewest = uses.min() ?? 0
        return swatches[uses.firstIndex(of: fewest) ?? 0].hex
    }
}
