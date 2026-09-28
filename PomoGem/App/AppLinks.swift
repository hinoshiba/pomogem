import Foundation

enum AppLinks {
    /// The product site's canonical address. Share cards and captions print
    /// it as branding, so it stays the same in every language.
    static let marketingWebsite = URL(
        string: "https://pomogem.hinoshiba.com/"
    )!

    /// The privacy policy from Info.plist (three release scripts pin that
    /// value, so it stays the canonical Japanese address) in the language the
    /// app is shown in.
    static var privacyPolicy: URL {
        let canonical: URL
        if let value = Bundle.main.object(
            forInfoDictionaryKey: "POMOGEM_PRIVACY_POLICY_URL"
        ) as? String,
           let url = URL(string: value) {
            canonical = url
        } else {
            canonical = URL(string: "https://pomogem.hinoshiba.com/#privacy")!
        }
        return inAppLanguage(canonical)
    }

    static var support: URL {
        inAppLanguage(URL(string: "https://pomogem.hinoshiba.com/#support")!)
    }

    static var commercialDisclosure: URL {
        inAppLanguage(URL(string: "https://pomogem.hinoshiba.com/#sales")!)
    }

    /// A page of the product site in the language the app's strings are shown
    /// in. The site is Japanese by default and serves English for `?lang=en`,
    /// the same addresses the en-US App Store listing uses
    /// (`https://pomogem.hinoshiba.com/?lang=en#privacy`). Japanese, and any
    /// other address, stays exactly as given.
    static func inAppLanguage(
        _ url: URL,
        localization: String? = Bundle.main.preferredLocalizations.first
    ) -> URL {
        guard let localization,
              Locale.Language(identifier: localization).languageCode == .english,
              url.host == siteHost,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        var items = (components.queryItems ?? []).filter { $0.name != "lang" }
        items.append(URLQueryItem(name: "lang", value: "en"))
        components.queryItems = items
        return components.url ?? url
    }

    private static let siteHost = "pomogem.hinoshiba.com"

    static let sourceCode = URL(
        string: "https://github.com/hinoshiba/pomogem"
    )!

    static let standardEULA = URL(
        string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
    )!

    /// The App Store ID of com.hinoshiba.pomogem (AppStore/configuration.yml).
    static let appStoreID = "6809139517"

    /// product-08. Opens the App Store's review sheet for this app. Only ever
    /// behind a row the person taps; the automatic prompt keeps its own gate.
    static let appStoreWriteReview = URL(
        string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review"
    )!

    static let supportEmail = "support@hinoshiba.com"

    /// settings-07. A mailto: draft to support. Every character outside
    /// RFC 3986's unreserved set is percent-encoded, including `&`, `=` and
    /// `+`, which URLComponents' query items would leave as they are and some
    /// mail apps would read as separators or spaces.
    static func supportMail(subject: String, body: String) -> URL? {
        // ASCII only: CharacterSet.alphanumerics would let kana through.
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        func encoded(_ value: String) -> String? {
            value.addingPercentEncoding(withAllowedCharacters: unreserved)
        }
        guard let subject = encoded(subject), let body = encoded(body) else { return nil }
        return URL(string: "mailto:\(supportEmail)?subject=\(subject)&body=\(body)")
    }
}
