import Foundation
import XCTest

/// The String Catalog sources, read from the checkout like the StoreKit test
/// in LocalPreviewLaunchPolicyTests.
///
/// Xcode marks stale or untranslated strings only inside the IDE and never fails
/// `xcodebuild`, so these rules are the gate every change runs through. The
/// code-to-catalog half (keys the compiler extracted) lives in
/// `Scripts/l10n/l10n.py check --derived-data`, which CI runs after this suite.
final class LocalizationCatalogTests: XCTestCase {
    private var map: LocalizationTestSupport.TableMap!

    override func setUpWithError() throws {
        map = try LocalizationTestSupport.tableMap()
    }

    func testEveryTableHasOneJapaneseSourceCatalog() throws {
        XCTAssertEqual(map.sourceLanguage, "ja")
        XCTAssertTrue(map.shippingLanguages.contains("ja"), "Japanese must always ship")
        XCTAssertFalse(map.catalogs.isEmpty)
        XCTAssertNil(map.catalogs["Localizable"], "The default table must stay empty so untabled strings stay detectable")
        for (table, path) in map.catalogs {
            XCTAssertEqual((path as NSString).lastPathComponent, "\(table).xcstrings", "the catalog file name is the table name")
            let catalog = try LocalizationCatalogFile(table: table, relativePath: path)
            XCTAssertEqual(catalog.sourceLanguage, "ja", path)
            XCTAssertEqual(catalog.version, "1.0", path)
            XCTAssertEqual(Set(catalog.root.keys), ["sourceLanguage", "strings", "version"], path)
        }
    }

    /// A stray catalog (including a default Localizable.xcstrings) or a legacy
    /// `.strings` file would silently take strings the table map assigns elsewhere.
    func testNoCatalogOrLegacyStringsOutsideTheTableMap() throws {
        let expected = Set(map.catalogs.values).union(map.infoPlistCatalogs.map(\.catalog))
        var found: Set<String> = []
        var legacy: [String] = []
        for root in map.sourceRoots {
            let base = LocalizationTestSupport.repositoryRoot.appendingPathComponent(root).resolvingSymlinksInPath()
            let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                let relative = root + String(url.resolvingSymlinksInPath().path.dropFirst(base.path.count))
                switch url.pathExtension {
                case "xcstrings": found.insert(relative)
                case "lproj", "strings", "stringsdict": legacy.append(relative)
                default: break
                }
            }
        }
        XCTAssertEqual(found, expected)
        XCTAssertEqual(legacy, [], "Use String Catalogs, not .lproj/.strings files")
    }

    /// The Japanese display name and permission texts come from these catalogs at
    /// runtime, so they must repeat Info.plist exactly (scripts pin ポモジェム).
    func testInfoPlistCatalogsRepeatInfoPlistExactly() throws {
        XCTAssertEqual(map.infoPlistCatalogs.count, 3)
        for item in map.infoPlistCatalogs {
            let catalog = try LocalizationCatalogFile(table: "InfoPlist", relativePath: item.catalog)
            XCTAssertEqual(catalog.sourceLanguage, "ja", item.catalog)
            let plistURL = LocalizationTestSupport.repositoryRoot.appendingPathComponent(item.infoPlist)
            let info = try XCTUnwrap(
                PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
            )
            let localizable = info.keys.filter { $0 == "CFBundleDisplayName" || ($0.hasPrefix("NS") && $0.hasSuffix("UsageDescription")) }
            XCTAssertEqual(Set(catalog.strings.keys), Set(localizable), "\(item.catalog) keys")
            XCTAssertNotNil(catalog.strings["CFBundleDisplayName"], "every bundle needs an explicit ja value to get ja.lproj")
            for (key, entry) in catalog.strings {
                XCTAssertEqual(entry["extractionState"] as? String, "manual", "\(item.catalog) \(key)")
                let localizations = LocalizationCatalogFile.localizations(of: entry)
                for language in map.shippingLanguages {
                    let units = LocalizationCatalogFile.units(of: localizations[language] ?? [:])
                    XCTAssertEqual(units.count, 1, "\(item.catalog) \(key) needs one \(language) value")
                    XCTAssertEqual(units.first?.state, "translated", "\(item.catalog) \(key) [\(language)]")
                    if language == map.sourceLanguage {
                        XCTAssertEqual(units.first?.value, info[key] as? String, "\(item.catalog) \(key) differs from \(item.infoPlist)")
                    } else {
                        XCTAssertFalse(LocalizationTestSupport.containsJapanese(units.first?.value ?? ""), "\(item.catalog) \(key) [\(language)]")
                    }
                }
            }
        }
    }

    /// Main stays shippable in Japanese: a language gets values only after it is
    /// activated in shipping_languages (Docs/Localization.md).
    func testCatalogsHoldOnlyShippingLanguages() throws {
        let allowed = Set(map.shippingLanguages)
        for (table, path) in map.catalogs.merging(
            map.infoPlistCatalogs.map { ("InfoPlist \($0.bundle)", $0.catalog) },
            uniquingKeysWith: { first, _ in first }
        ) {
            let catalog = try LocalizationCatalogFile(table: table, relativePath: path)
            for (key, entry) in catalog.strings {
                let languages = Set(LocalizationCatalogFile.localizations(of: entry).keys)
                XCTAssertTrue(languages.isSubset(of: allowed), "\(path) \(key): \(languages.subtracting(allowed).sorted()) is not activated")
            }
        }
    }

    /// A table is activated once it holds any value in a target language. From
    /// then on every live key needs a translated value with the same arguments
    /// and no Japanese left in it. (Vacuous until English is activated.)
    func testActivatedTablesAreCompleteAndWellFormed() throws {
        for language in map.targetLanguages {
            for (table, path) in map.catalogs {
                let catalog = try LocalizationCatalogFile(table: table, relativePath: path)
                let activated = catalog.strings.values.contains { LocalizationCatalogFile.localizations(of: $0)[language] != nil }
                guard activated else { continue }
                for (key, entry) in catalog.strings {
                    if entry["extractionState"] as? String == "stale" || entry["shouldTranslate"] as? Bool == false { continue }
                    guard let localization = LocalizationCatalogFile.localizations(of: entry)[language] else {
                        XCTFail("\(path) \(key): no \(language) value")
                        continue
                    }
                    let source = LocalizationFormatArguments.of(catalog.sourceText(key: key, entry: entry))
                    let substitutions = localization["substitutions"] as? [String: Any] ?? [:]
                    let units = LocalizationCatalogFile.units(of: localization)
                    XCTAssertFalse(units.isEmpty, "\(path) \(key) [\(language)] has no value")
                    for unit in units {
                        XCTAssertEqual(unit.state, "translated", "\(path) \(key) [\(language)] \(unit.label)")
                        XCTAssertFalse(LocalizationTestSupport.containsJapanese(unit.value), "\(path) \(key) [\(language)] \(unit.label): \(unit.value)")
                        XCTAssertEqual(
                            LocalizationFormatArguments.of(unit.value, substitutions: substitutions),
                            source,
                            "\(path) \(key) [\(language)] \(unit.label): arguments differ from the source"
                        )
                    }
                }
            }
        }
    }

    /// The separator and counter keys the formatting helpers use live in Common.
    /// Losing one would make English fall back to the Japanese pattern.
    func testCommonCatalogHoldsTheFormattingKeys() throws {
        let path = try XCTUnwrap(map.catalogs["Common"])
        let catalog = try LocalizationCatalogFile(table: "Common", relativePath: path)
        for key in ["%@g", "%@kg", "%lld粒", "・"] {
            XCTAssertNotNil(catalog.strings[key], "Common.xcstrings lacks \(key); build and run Scripts/l10n/l10n.py sync")
        }
    }
}
