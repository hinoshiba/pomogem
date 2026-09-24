import XCTest

/// The language every UI test launches PomoGem in.
///
/// UI tests find elements by their Japanese labels. Today the app has only a
/// Japanese localization, but once it also ships English a Simulator or iPhone
/// set to English would open the app in English and those queries would miss.
/// Every launch goes through this helper so none can forget the pin;
/// `Scripts/l10n/l10n.py check` rejects a launch that is not pinned.
enum PomoGemUITestLanguage {
    static let japaneseArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]

    /// Launch in Japanese with the Japan region. Idempotent: a relaunch of the
    /// same application keeps exactly one language pin.
    static func configureJapanese(_ application: XCUIApplication) {
        application.launchArguments = withoutLanguagePin(application.launchArguments) + japaneseArguments
    }

    private static func withoutLanguagePin(_ arguments: [String]) -> [String] {
        var result: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            if ["-AppleLanguages", "-AppleLocale"].contains(arguments[index]) {
                index += 2
                continue
            }
            result.append(arguments[index])
            index += 1
        }
        return result
    }
}
