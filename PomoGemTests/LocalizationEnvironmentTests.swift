import Foundation
import XCTest
@testable import PomoGem

/// The language the suite runs in, and the localizations each built bundle ships.
///
/// Hundreds of tests assert Japanese copy. They pass on an English Simulator
/// today only because the app has no other localization; the day it ships
/// English they would all switch. The scheme's test action pins language ja and
/// region JP, CI also passes `-testLanguage ja -testRegion JP`, and this test
/// fails with the fix spelled out if either goes missing.
final class LocalizationEnvironmentTests: XCTestCase {
    func testHostRunsInJapanese() {
        let preferred = Locale.preferredLanguages.first ?? "<none>"
        let fix = "Run tests through the PomoGem scheme (its test action pins ja / JP) "
            + "or pass -testLanguage ja -testRegion JP to xcodebuild."
        XCTAssertTrue(preferred.hasPrefix("ja"), "The test host prefers \(preferred), not Japanese. \(fix)")
        XCTAssertEqual(Locale.current.language.languageCode, .japanese, "Locale is \(Locale.current.identifier). \(fix)")
        XCTAssertEqual(Locale.current.region, .japan, "Locale is \(Locale.current.identifier). \(fix)")
        XCTAssertEqual(Bundle.main.preferredLocalizations.first, "ja", fix)
    }

    /// Every bundle carries exactly the shipping localizations. A bundle without
    /// `ja.lproj` would let iOS format its dates and units in another language,
    /// and an `en.lproj` before activation would ship half-translated English.
    func testEveryBundleShipsExactlyTheShippingLocalizations() throws {
        let map = try LocalizationTestSupport.tableMap()
        for (name, bundle) in try LocalizationTestSupport.productBundles() {
            let shipped = Set(bundle.localizations).subtracting(["Base"])
            XCTAssertEqual(shipped, Set(map.shippingLanguages), "\(name) localizations")
        }
    }

    func testEveryBundleNamesItselfInJapaneseLikeItsInfoPlist() throws {
        let map = try LocalizationTestSupport.tableMap()
        let bundles = Dictionary(uniqueKeysWithValues: try LocalizationTestSupport.productBundles().map { ($0.name, $0.bundle) })
        for item in map.infoPlistCatalogs {
            let bundle = try XCTUnwrap(bundles[item.bundle], item.bundle)
            let strings = try XCTUnwrap(
                LocalizationTestSupport.infoPlistStrings(in: bundle, language: map.sourceLanguage),
                "\(item.bundle) has no \(map.sourceLanguage).lproj/InfoPlist.strings"
            )
            let displayName = try XCTUnwrap(strings["CFBundleDisplayName"], "\(item.bundle) display name")
            XCTAssertEqual(displayName, bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, item.bundle)
            for (key, value) in strings {
                XCTAssertEqual(value, bundle.infoDictionary?[key] as? String, "\(item.bundle) \(key)")
            }
        }
        XCTAssertEqual(Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String, "ポモジェム")
    }

    /// The fallback language iOS uses when a device prefers none of the shipped
    /// ones comes from DEVELOPMENT_LANGUAGE in project.yml. The table map must
    /// say the same, because it decides whether catalogs need explicit Japanese.
    func testEveryBundleFallsBackToTheConfiguredDevelopmentRegion() throws {
        let map = try LocalizationTestSupport.tableMap()
        for (name, bundle) in try LocalizationTestSupport.productBundles() {
            XCTAssertEqual(
                bundle.developmentLocalization, map.developmentRegion,
                "\(name): change DEVELOPMENT_LANGUAGE in project.yml and development_region in Scripts/l10n/table-map.json together"
            )
        }
    }

    /// A Japanese device reads Japanese from every key of every table.
    ///
    /// Japanese lives in the catalog keys. xcstringstool writes
    /// `ja.lproj/<Table>.strings` only for explicit Japanese values, so with the
    /// development region set to en a Japanese device finds no Japanese table and
    /// reads `en.lproj` instead: the whole screen turns English (iOS 26.5
    /// Simulator probe, 2026-09-25). `l10n.py sync` writes the Japanese values
    /// whenever the table map's development region is not Japanese. While it is,
    /// a missing value falls back to the key, and this test holds trivially.
    func testJapaneseDevicesReadJapaneseFromEveryTable() throws {
        let map = try LocalizationTestSupport.tableMap()
        XCTAssertEqual(Bundle.main.preferredLocalizations.first, "ja", "run the suite in Japanese")
        for (name, bundle) in try LocalizationTestSupport.productBundles() {
            for table in map.catalogBundles[name] ?? [] {
                let catalog = try LocalizationCatalogFile(table: table, relativePath: try XCTUnwrap(map.catalogs[table]))
                for (key, entry) in catalog.strings where entry["extractionState"] as? String != "stale" {
                    let japanese = catalog.sourceText(key: key, entry: entry)
                    let shown = bundle.localizedString(forKey: key, value: japanese, table: table)
                    XCTAssertEqual(
                        shown, japanese,
                        "\(name) \(table) \(key): a Japanese device reads \(shown). Run Scripts/l10n/l10n.py sync (Docs/Localization.md)"
                    )
                }
            }
        }
    }

    /// Enabled by the English integration: `shipping_languages` gains "en" in
    /// Scripts/l10n/table-map.json. Until then this test is skipped on purpose,
    /// because main ships Japanese only.
    func testEnglishShipsWithEveryTableOnceActivated() throws {
        guard try LocalizationTestSupport.isShipping("en") else {
            throw XCTSkip(
                "English is not activated yet. Adding \"en\" to shipping_languages turns this on: "
                    + "then every bundle must contain en.lproj with each non-empty table."
            )
        }
        let map = try LocalizationTestSupport.tableMap()
        XCTAssertTrue(Set(Bundle.main.localizations).isSuperset(of: ["ja", "en"]))
        for (name, bundle) in try LocalizationTestSupport.productBundles() {
            let english = try LocalizationTestSupport.englishBundle(in: bundle)
            XCTAssertNotNil(
                LocalizationTestSupport.infoPlistStrings(in: bundle, language: "en")?["CFBundleDisplayName"],
                "\(name) en.lproj/InfoPlist.strings"
            )
            for table in map.catalogBundles[name] ?? [] {
                let catalog = try LocalizationCatalogFile(table: table, relativePath: try XCTUnwrap(map.catalogs[table]))
                guard !catalog.strings.isEmpty else { continue }
                let compiled = english.url(forResource: table, withExtension: "strings")
                    ?? english.url(forResource: table, withExtension: "stringsdict")
                XCTAssertNotNil(compiled, "\(name) en.lproj has no \(table) table")
            }
        }
    }
}
