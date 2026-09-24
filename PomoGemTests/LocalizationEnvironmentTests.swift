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
