import Foundation

enum AppLinks {
    static var privacyPolicy: URL {
        if let value = Bundle.main.object(
            forInfoDictionaryKey: "TSUMIBEN_PRIVACY_POLICY_URL"
        ) as? String,
           let url = URL(string: value) {
            return url
        }
        return URL(string: "https://tumiben.hinoshiba.com/privacy/")!
    }

    static let support = URL(
        string: "https://tumiben.hinoshiba.com/support/"
    )!

    static let standardEULA = URL(
        string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
    )!
}
