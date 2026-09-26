import Foundation

enum AppLinks {
    static let marketingWebsite = URL(
        string: "https://pomogem.hinoshiba.com/"
    )!

    static var privacyPolicy: URL {
        if let value = Bundle.main.object(
            forInfoDictionaryKey: "POMOGEM_PRIVACY_POLICY_URL"
        ) as? String,
           let url = URL(string: value) {
            return url
        }
        return URL(string: "https://pomogem.hinoshiba.com/#privacy")!
    }

    static let support = URL(
        string: "https://pomogem.hinoshiba.com/#support"
    )!

    static let commercialDisclosure = URL(
        string: "https://pomogem.hinoshiba.com/#sales"
    )!

    static let sourceCode = URL(
        string: "https://github.com/hinoshiba/pomogem"
    )!

    static let standardEULA = URL(
        string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
    )!

    /// The raw-stone widget's link to the start screen (`StartFocusLink`).
    static let startFocus = StartFocusLink.url

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
