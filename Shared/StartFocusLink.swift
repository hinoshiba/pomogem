import Foundation

/// The link the raw-stone widget opens (D19, Docs/GemExperienceDesign.md
/// §8.7): PomoGem's start screen, Home, where the focus button is. It is
/// the same URL for everyone and carries no data; opening it only shows
/// Home and never starts a timer. `pomogem` is the app's URL scheme
/// (Info.plist `CFBundleURLSchemes`).
enum StartFocusLink {
    static let url = URL(string: "pomogem://start")!

    static func matches(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "pomogem"
            && url.host?.lowercased() == "start"
    }
}
