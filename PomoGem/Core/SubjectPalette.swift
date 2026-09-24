import Foundation

/// The theme colour palette: the one ordered list of swatches that theme
/// setup offers (onboarding and the theme editor). The jar reads the same
/// list: a swatch's index keys its Differentiate Without Color mark
/// (`GemThemeMark`), and the gem tone mapping is tested against every
/// swatch, so curating this list retunes all of them at once.
///
/// Stored theme colours are never rewritten from here: a theme keeps the
/// hex it was saved with, and a hex that is not (or no longer) in the list
/// simply has no palette index.
enum SubjectPalette {
    struct Swatch: Hashable, Sendable {
        let hex: String
        let name: String
    }

    static let swatches: [Swatch] = [
        Swatch(hex: Constants.Color.english, name: "朱色"),
        Swatch(hex: Constants.Color.mathematics, name: "瑠璃"),
        Swatch(hex: Constants.Color.japanese, name: "紅藤"),
        Swatch(hex: Constants.Color.science, name: "緑青"),
        Swatch(hex: Constants.Color.socialStudies, name: "菫"),
        Swatch(hex: "#D6863A", name: "琥珀"),
        Swatch(hex: "#36A7AE", name: "青緑"),
        Swatch(hex: "#D56B82", name: "珊瑚"),
        Swatch(hex: "#739B45", name: "若草"),
        Swatch(hex: "#5967C8", name: "藍"),
        Swatch(hex: "#A76A3F", name: "赤銅"),
        Swatch(hex: "#5688A8", name: "空色")
    ]

    static var hexes: [String] { swatches.map(\.hex) }

    /// Position of `hex` in the palette (case- and `#`-insensitive), or nil
    /// for a colour outside it.
    static func index(of hex: String) -> Int? {
        let key = normalized(hex)
        return swatches.firstIndex { normalized($0.hex) == key }
    }

    static func normalized(_ hex: String) -> String {
        hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).uppercased()
    }
}
