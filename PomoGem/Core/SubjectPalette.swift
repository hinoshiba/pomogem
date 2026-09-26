import Foundation

/// The theme colour palette: the one ordered list of swatches that theme
/// setup offers (onboarding and the theme editor). The gem tone mapping is
/// tested against every swatch, so curating this list retunes all of them
/// at once. The Differentiate Without Color marks (`GemThemeMark`) are keyed
/// by hex, never by position here, so reordering the list moves no mark.
///
/// Stored theme colours are never rewritten from here: a theme keeps the
/// hex it was saved with, and a hex that is not (or no longer) in the list
/// simply has no palette index.
enum SubjectPalette {
    struct Swatch: Hashable, Sendable {
        let hex: String
        /// The swatch's display name in the theme editor. Never stored: a
        /// theme saves only the hex.
        let name: String
    }

    static let swatches: [Swatch] = [
        Swatch(hex: Constants.Color.english, name: String(localized: "朱色", table: "Settings", comment: "Theme colour swatch name (Vermilion)")),
        Swatch(hex: Constants.Color.mathematics, name: String(localized: "瑠璃", table: "Settings", comment: "Theme colour swatch name (Lapis lazuli)")),
        Swatch(hex: Constants.Color.japanese, name: String(localized: "紅藤", table: "Settings", comment: "Theme colour swatch name (Pink wisteria)")),
        Swatch(hex: Constants.Color.science, name: String(localized: "緑青", table: "Settings", comment: "Theme colour swatch name (Verdigris)")),
        Swatch(hex: Constants.Color.socialStudies, name: String(localized: "菫", table: "Settings", comment: "Theme colour swatch name (Violet)")),
        Swatch(hex: "#D6863A", name: String(localized: "琥珀", table: "Settings", comment: "Theme colour swatch name (Amber)")),
        Swatch(hex: "#36A7AE", name: String(localized: "青緑", table: "Settings", comment: "Theme colour swatch name (Teal)")),
        Swatch(hex: "#D56B82", name: String(localized: "珊瑚", table: "Settings", comment: "Theme colour swatch name (Coral)")),
        Swatch(hex: "#739B45", name: String(localized: "若草", table: "Settings", comment: "Theme colour swatch name (Young leaf green)")),
        Swatch(hex: "#5967C8", name: String(localized: "藍", table: "Settings", comment: "Theme colour swatch name (Indigo)")),
        Swatch(hex: "#A76A3F", name: String(localized: "赤銅", table: "Settings", comment: "Theme colour swatch name (Copper)")),
        Swatch(hex: "#5688A8", name: String(localized: "空色", table: "Settings", comment: "Theme colour swatch name (Sky blue)"))
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
