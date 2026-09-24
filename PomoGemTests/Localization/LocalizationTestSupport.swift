import Foundation
import XCTest

/// Shared plumbing for localization tests (Docs/Localization.md).
///
/// The suite runs in Japanese (LocalizationEnvironmentTests guards that). A test
/// that needs another language resolves it explicitly, through that language's
/// `.lproj` bundle and a matching locale, instead of changing the process
/// language for everyone else.
enum LocalizationTestSupport {
    static let japanese = Locale(identifier: "ja_JP")
    static let english = Locale(identifier: "en_US")

    /// The checkout these tests were compiled from, for reading catalogs and
    /// configuration directly (the Simulator shares the Mac's file system).
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    struct InfoPlistCatalog: Decodable {
        let catalog: String
        let infoPlist: String
        let bundle: String

        enum CodingKeys: String, CodingKey {
            case catalog
            case infoPlist = "info_plist"
            case bundle
        }
    }

    /// `Scripts/l10n/table-map.json`, the single source for tables, catalogs
    /// and the languages every bundle ships.
    struct TableMap: Decodable {
        let sourceLanguage: String
        let shippingLanguages: [String]
        let sourceRoots: [String]
        let catalogs: [String: String]
        let catalogBundles: [String: [String]]
        let infoPlistCatalogs: [InfoPlistCatalog]
        let bundlePaths: [String: String]

        enum CodingKeys: String, CodingKey {
            case sourceLanguage = "source_language"
            case shippingLanguages = "shipping_languages"
            case sourceRoots = "source_roots"
            case catalogs
            case catalogBundles = "catalog_bundles"
            case infoPlistCatalogs = "info_plist_catalogs"
            case bundlePaths = "bundle_paths"
        }

        var targetLanguages: [String] {
            shippingLanguages.filter { $0 != sourceLanguage }
        }
    }

    static func tableMap() throws -> TableMap {
        let url = repositoryRoot.appendingPathComponent("Scripts/l10n/table-map.json")
        return try JSONDecoder().decode(TableMap.self, from: Data(contentsOf: url))
    }

    static func isShipping(_ language: String) throws -> Bool {
        try tableMap().shippingLanguages.contains(language)
    }

    /// One language's `.lproj` inside `bundle`. Skips the calling test until the
    /// language ships, so English expectations can be written before activation.
    static func bundle(for language: String, in bundle: Bundle = .main) throws -> Bundle {
        guard try isShipping(language) else {
            throw XCTSkip(
                "\(language) is not activated yet: it is missing from shipping_languages in Scripts/l10n/table-map.json."
            )
        }
        guard let path = bundle.path(forResource: language, ofType: "lproj"),
              let localized = Bundle(path: path)
        else {
            XCTFail("\(language) ships, but \(bundle.bundleURL.lastPathComponent) has no \(language).lproj")
            throw XCTSkip("no \(language).lproj")
        }
        return localized
    }

    static func englishBundle(in bundle: Bundle = .main) throws -> Bundle {
        try self.bundle(for: "en", in: bundle)
    }

    /// The app, the widget extension and the Screen Time monitor, by the names
    /// used in the table map.
    static func productBundles() throws -> [(name: String, bundle: Bundle)] {
        try tableMap().bundlePaths.sorted { $0.key < $1.key }.map { name, relativePath in
            let url = relativePath == "."
                ? Bundle.main.bundleURL
                : Bundle.main.bundleURL.appendingPathComponent(relativePath)
            guard let bundle = Bundle(url: url) else {
                throw XCTSkip("\(name) is not embedded at \(url.path)")
            }
            return (name, bundle)
        }
    }

    /// The compiled `InfoPlist.strings` of one localization.
    static func infoPlistStrings(in bundle: Bundle, language: String) -> [String: String]? {
        guard let url = bundle.url(
            forResource: "InfoPlist",
            withExtension: "strings",
            subdirectory: nil,
            localization: language
        ),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String]
    }

    /// Whether text still contains kana, kanji, Japanese punctuation or
    /// full-width forms (the same ranges as Scripts/l10n/l10n.py).
    static func containsJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3000...0x303F, 0x3040...0x309F, 0x30A0...0x30FF, 0x3400...0x4DBF,
                 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
                return true
            default:
                return false
            }
        }
    }
}

/// One `.xcstrings` source file, read straight from the checkout.
struct LocalizationCatalogFile {
    struct Unit {
        let label: String
        let state: String?
        let value: String
    }

    let table: String
    let relativePath: String
    let root: [String: Any]

    init(table: String, relativePath: String) throws {
        self.table = table
        self.relativePath = relativePath
        let url = LocalizationTestSupport.repositoryRoot.appendingPathComponent(relativePath)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        root = try XCTUnwrap(object as? [String: Any], "\(relativePath) is not a JSON object")
    }

    var sourceLanguage: String? { root["sourceLanguage"] as? String }
    var version: String? { root["version"] as? String }
    var strings: [String: [String: Any]] { root["strings"] as? [String: [String: Any]] ?? [:] }

    static func localizations(of entry: [String: Any]) -> [String: [String: Any]] {
        entry["localizations"] as? [String: [String: Any]] ?? [:]
    }

    /// The source text of a key: its explicit source-language value when the key
    /// is semantic (`defaultValue:`), otherwise the Japanese key itself.
    func sourceText(key: String, entry: [String: Any]) -> String {
        let unit = Self.localizations(of: entry)[sourceLanguage ?? "ja"]?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String ?? key
    }

    /// Every leaf value of one language, including plural and device variations.
    static func units(of localization: [String: Any], label: String = "value") -> [Unit] {
        var result: [Unit] = []
        if let unit = localization["stringUnit"] as? [String: Any] {
            result.append(Unit(label: label, state: unit["state"] as? String, value: unit["value"] as? String ?? ""))
        }
        for (kind, forms) in localization["variations"] as? [String: [String: [String: Any]]] ?? [:] {
            for (form, nested) in forms.sorted(by: { $0.key < $1.key }) {
                result += units(of: nested, label: "\(label).\(kind).\(form)")
            }
        }
        return result
    }
}

/// printf-style arguments of a localized format, by argument position, the
/// way String Catalogs match them across languages (Scripts/l10n/l10n.py).
enum LocalizationFormatArguments {
    private static let pattern = try! NSRegularExpression(
        pattern: #"%(?:(\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA%])|%#@([A-Za-z0-9_]+)@"#
    )

    static func of(_ text: String, substitutions: [String: Any] = [:]) -> [Int: String] {
        var arguments: [Int: String] = [:]
        var implicit = 0
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            func group(_ index: Int) -> String? {
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
            if let name = group(4) {
                let substitution = substitutions[name] as? [String: Any]
                let position = substitution?["argNum"] as? Int ?? -1
                arguments[position] = substitution?["formatSpecifier"] as? String ?? "?"
                continue
            }
            let conversion = group(3) ?? ""
            if conversion == "%" { continue }
            let position: Int
            if let explicit = group(1).flatMap(Int.init) {
                position = explicit
            } else {
                implicit += 1
                position = implicit
            }
            arguments[position] = (group(2) ?? "") + conversion
        }
        return arguments
    }
}
