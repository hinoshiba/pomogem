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
}
