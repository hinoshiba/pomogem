import Foundation
import XCTest
@testable import PomoGem

/// English for the strings the localization prep owns (Docs/Localization.md):
/// the `Common` table (Constants.UIStrings, the Home atmospheres, the sheet's
/// Close button, the wordmark, the formatting helpers), the three InfoPlist
/// catalogs, DurationPresentation, the language-aware AppLinks and the
/// third-language fallback.
///
/// English is resolved explicitly through the `en.lproj` bundles; the process
/// stays Japanese, and the Japanese of the same strings is pinned here too.
final class CommonLocalizationTests: XCTestCase {
    private let en = LocalizationTestSupport.english
    private let ja = LocalizationTestSupport.japanese

    /// The English value of a Common key, formatted like the app formats it.
    private func english(_ key: String, _ arguments: CVarArg...) throws -> String {
        let bundle = try LocalizationTestSupport.englishBundle()
        let format = bundle.localizedString(forKey: key, value: "<missing \(key)>", table: "Common")
        return arguments.isEmpty ? format : String(format: format, locale: en, arguments: arguments)
    }

    // MARK: Constants.UIStrings

    func testFixedCopyStaysJapaneseOnJapaneseDevices() {
        XCTAssertEqual(Constants.UIStrings.resume, "再開する")
        XCTAssertEqual(Constants.UIStrings.pause, "一時停止")
        XCTAssertEqual(Constants.UIStrings.giveUp, "今日はここまで")
        XCTAssertEqual(Constants.UIStrings.jarEmptyTitle, "まだ空っぽ。")
        XCTAssertEqual(Constants.UIStrings.goldToast, "✦ 金の粒が出た！ +250g")
        XCTAssertEqual(Constants.UIStrings.prismToast, "❖ 虹の粒！！ +250g")
        XCTAssertEqual(Constants.UIStrings.goldToast(grams: 1_250), "✦ 金の粒が出た！ +1250g", "never digit-grouped, as before")
        XCTAssertEqual(Constants.UIStrings.manualCapToast, "自己申告はこの端末で1日3回まで")
        XCTAssertEqual(Constants.UIStrings.fairnessNote, "自己申告の粒は破線つき。総質量には入るが、シェアの既定は実測のみ。")
        XCTAssertEqual(Constants.UIStrings.interruptionNote, "画面を離れたので、この回は自己申告あつかいになった")
        XCTAssertEqual(Constants.UIStrings.processTerminatedNote, "アプリが終了したため、この回は積まれませんでした")
        XCTAssertEqual(Constants.UIStrings.eveningNotification, "瓶が待ってる。今日のひと粒、積んでいく？")
        XCTAssertEqual(Constants.UIStrings.paywallTitle, "ポモジェムPro")
        XCTAssertEqual(Constants.UIStrings.customDurationRange, "1〜360分")
        XCTAssertEqual(Constants.UIStrings.dropToast(subject: "数学"), "数学 +250g 積んだ")
    }

    func testFixedCopyInEnglish() throws {
        XCTAssertEqual(try english("再開する"), "Resume")
        XCTAssertEqual(try english("一時停止"), "Pause")
        XCTAssertEqual(try english("今日はここまで"), "Stop for Today")
        XCTAssertEqual(try english("まだ空っぽ。"), "Still empty.")
        XCTAssertEqual(try english("自己申告はこの端末で1日3回まで"), "Up to 3 self-reported entries a day on this device")
        XCTAssertEqual(
            try english("画面を離れたので、この回は自己申告あつかいになった"),
            "You left the screen, so this session counts as self-reported."
        )
        XCTAssertEqual(
            try english("アプリが終了したため、この回は積まれませんでした"),
            "The app was closed, so this session wasn't added."
        )
        XCTAssertEqual(
            try english("瓶が待ってる。今日のひと粒、積んでいく？"),
            "Your jar is here whenever you're ready. Add a gem today?"
        )
        XCTAssertEqual(try english("ポモジェムPro"), "PomoGem Pro")
        XCTAssertEqual(
            try english("%lld〜%lld分", Constants.Timer.customMinimumMinutes, Constants.Timer.customMaximumMinutes),
            "1–360 min"
        )
        XCTAssertEqual(try english("%@ +250g 積んだ", "Math"), "Added 250 g to Math")

        let bundle = try LocalizationTestSupport.englishBundle()
        let grams = MassText.grams("600", bundle: bundle, locale: en)
        XCTAssertEqual(try english("✦ 金の粒が出た！ +%@", grams), "✦ A gold gem! +600 g")
        XCTAssertEqual(try english("❖ 虹の粒！！ +%@", grams), "❖ A rainbow gem!! +600 g")
    }

    // MARK: Theme and wordmark

    func testAtmospheresAndSharedControlsInBothLanguages() throws {
        XCTAssertEqual(HomeAtmosphere.allCases.map(\.title), ["深夜", "オーロラ", "朝凪", "書斎"])
        XCTAssertEqual(HomeAtmosphere.allCases.map(\.subtitle), ["静かな定番", "光に包まれる", "昼にも軽やか", "仕事にも馴染む"])
        XCTAssertEqual(PomoGemSheetCloseButton(action: {}).accessibilityLabel, "閉じる")

        XCTAssertEqual(
            try ["深夜", "オーロラ", "朝凪", "書斎"].map { try english($0) },
            ["Midnight", "Aurora", "Morning Calm", "Den"]
        )
        XCTAssertEqual(
            try ["静かな定番", "光に包まれる", "昼にも軽やか", "仕事にも馴染む"].map { try english($0) },
            ["A quiet classic", "Wrapped in light", "Airy, even by day", "Suits work, too"]
        )
        XCTAssertEqual(try english("閉じる"), "Close")
        XCTAssertEqual(try english("ポモジェム"), "PomoGem")
    }

    // MARK: DurationPresentation

    /// DurationPresentation is DurationText now: the Japanese stays exactly what
    /// DurationPresentationTests pins, and English gets Foundation's units.
    func testFocusDurationsInBothLanguages() {
        let minutes = [0, 1, 59, 60, 75, 250, 7_425, 74_040, 74_045]
        XCTAssertEqual(
            minutes.map { DurationPresentation.minutesLabel($0, locale: ja) },
            ["0分", "1分", "59分", "1時間", "1時間15分", "4時間10分", "123時間45分", "1,234時間", "1,234時間5分"]
        )
        XCTAssertEqual(
            minutes.map { DurationPresentation.minutesLabel($0, locale: en) },
            ["0 min", "1 min", "59 min", "1 hr", "1 hr 15 min", "4 hr 10 min", "123 hr 45 min", "1,234 hr", "1,234 hr 5 min"]
        )
        XCTAssertEqual(DurationPresentation.minutesLabel(-5, locale: en), "0 min")
        for value in 0 ... 3_000 {
            XCTAssertEqual(DurationPresentation.minutesLabel(value), DurationPresentation.minutesLabel(value, locale: ja))
        }
    }

    // MARK: AppLinks

    func testSiteLinksOpenTheSiteInTheAppsLanguage() throws {
        let support = URL(string: "https://pomogem.hinoshiba.com/#support")!
        XCTAssertEqual(AppLinks.support, support, "a Japanese device keeps the canonical address")
        XCTAssertEqual(AppLinks.commercialDisclosure.absoluteString, "https://pomogem.hinoshiba.com/#sales")
        XCTAssertEqual(
            AppLinks.privacyPolicy.absoluteString,
            Bundle.main.object(forInfoDictionaryKey: "POMOGEM_PRIVACY_POLICY_URL") as? String
        )

        XCTAssertEqual(AppLinks.inAppLanguage(support, localization: "ja"), support)
        XCTAssertEqual(AppLinks.inAppLanguage(support, localization: nil), support)
        XCTAssertEqual(AppLinks.inAppLanguage(support, localization: "en").absoluteString, "https://pomogem.hinoshiba.com/?lang=en#support")
        XCTAssertEqual(AppLinks.inAppLanguage(support, localization: "en-GB").absoluteString, "https://pomogem.hinoshiba.com/?lang=en#support")
        XCTAssertEqual(
            AppLinks.inAppLanguage(URL(string: "https://pomogem.hinoshiba.com/?lang=ja#sales")!, localization: "en").absoluteString,
            "https://pomogem.hinoshiba.com/?lang=en#sales"
        )
        XCTAssertEqual(AppLinks.inAppLanguage(AppLinks.sourceCode, localization: "en"), AppLinks.sourceCode, "only the product site has an English page")
        XCTAssertEqual(AppLinks.inAppLanguage(AppLinks.standardEULA, localization: "en"), AppLinks.standardEULA)
        XCTAssertEqual(AppLinks.marketingWebsite.absoluteString, "https://pomogem.hinoshiba.com/", "captions and cards keep the canonical address")
    }

    /// The English addresses are the ones the en-US App Store listing already uses.
    func testEnglishSiteLinksMatchTheEnglishStoreListing() throws {
        func listing(_ name: String) throws -> String {
            let url = LocalizationTestSupport.repositoryRoot.appendingPathComponent("AppStore/metadata/en-US/\(name)")
            return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let privacy = try XCTUnwrap(URL(string: "https://pomogem.hinoshiba.com/#privacy"))
        let support = try XCTUnwrap(URL(string: "https://pomogem.hinoshiba.com/#support"))
        XCTAssertEqual(AppLinks.inAppLanguage(privacy, localization: "en").absoluteString, try listing("privacy_url.txt"))
        XCTAssertEqual(AppLinks.inAppLanguage(support, localization: "en").absoluteString, try listing("support_url.txt"))
    }

    // MARK: InfoPlist and fallback

    func testBundlesNameThemselvesAndExplainPermissionsInEnglish() throws {
        let expectedNames = [
            "PomoGem.app": "PomoGem",
            "PomoGemWidgets.appex": "PomoGem",
            "PomoGemScreenTimeMonitor.appex": "PomoGem Screen Time"
        ]
        for (name, bundle) in try LocalizationTestSupport.productBundles() {
            _ = try LocalizationTestSupport.englishBundle(in: bundle)
            let strings = try XCTUnwrap(LocalizationTestSupport.infoPlistStrings(in: bundle, language: "en"), "\(name) en.lproj/InfoPlist.strings")
            XCTAssertEqual(strings["CFBundleDisplayName"], expectedNames[name], name)
            for (key, value) in strings {
                XCTAssertFalse(LocalizationTestSupport.containsJapanese(value), "\(name) \(key): \(value)")
            }
        }
        let app = try XCTUnwrap(LocalizationTestSupport.infoPlistStrings(in: .main, language: "en"))
        XCTAssertEqual(
            Set(app.keys),
            ["CFBundleDisplayName", "NSMotionUsageDescription", "NSPhotoLibraryAddUsageDescription", "NSAppleMusicUsageDescription"]
        )
    }

    /// Orchestrator decision (DECISIONS.md #1): a device that prefers neither
    /// Japanese nor English (Korean, Chinese, French ...) gets English, the
    /// development region of every bundle. Japanese devices keep Japanese.
    func testThirdLanguagesFallBackToEnglish() throws {
        XCTAssertEqual(try LocalizationTestSupport.tableMap().developmentRegion, "en")
        for (name, bundle) in try LocalizationTestSupport.productBundles() {
            XCTAssertEqual(bundle.developmentLocalization, "en", name)
            let localizations = bundle.localizations
            for preferences in [["ko-KR"], ["zh-Hans-CN"], ["fr-FR"], ["th-TH"]] {
                XCTAssertEqual(
                    Bundle.preferredLocalizations(from: localizations, forPreferences: preferences).first, "en",
                    "\(name) \(preferences)"
                )
            }
            for preferences in [["ja-JP"], ["ja"], ["ko-KR", "ja-JP"], ["zh-Hant-TW", "ja-JP", "en-US"]] {
                XCTAssertEqual(
                    Bundle.preferredLocalizations(from: localizations, forPreferences: preferences).first, "ja",
                    "\(name) \(preferences)"
                )
            }
        }
        // Formatting follows the strings: a Korean device reads English strings
        // and English units, with its own region.
        let korean = PomoGemLocale.locale(localization: "en", base: Locale(identifier: "ko_KR"))
        XCTAssertEqual(korean.language.languageCode, .english)
        XCTAssertEqual(korean.region, .southKorea)
        XCTAssertEqual(DurationPresentation.minutesLabel(75, locale: korean), "1 hr 15 min")
    }
}
