import Foundation

/// A free focus length an outside entry point may ask for. Pro lengths are
/// deliberately absent: a link, a widget or a Shortcut must never unlock a
/// custom duration the Home picker would not offer.
enum FocusStartPreset: Int, CaseIterable, Hashable, Sendable {
    case twentyFive = 25
    case fortyFive = 45
    case sixty = 60
    case ninety = 90

    var minutes: Int { rawValue }
    var seconds: Int { rawValue * 60 }

    init?(minutes: Int) {
        self.init(rawValue: minutes)
    }
}

/// Where an outside entry (a widget tap, a `pomogem://` link, Siri, Spotlight,
/// the Shortcuts app or the Action Button) asks the app to go. A route is a
/// constant: it carries no theme, record, mass or account data, which keeps
/// the widget extension that builds these URLs account-neutral.
enum AppEntryRoute: Hashable, Sendable {
    /// Back to the jar.
    case home
    /// Start a focus from Home, exactly as its start button would: the
    /// selected theme and, when no preset is given, the selected length.
    case startFocus(FocusStartPreset?)
}

/// The `pomogem://` URL scheme registered in Info.plist (notify-03).
///
/// - `pomogem://home`
/// - `pomogem://focus/start`
/// - `pomogem://focus/start?minutes=25` (25, 45, 60 or 90)
///
/// Anything else is ignored rather than guessed at, so a malformed or future
/// link opens the app where it was instead of starting something unexpected.
enum AppEntryLink {
    static let scheme = "pomogem"
    private static let minutesQueryName = "minutes"

    static var homeURL: URL {
        url(host: "home", path: "", queryItems: nil)
    }

    static func focusStartURL(_ preset: FocusStartPreset? = nil) -> URL {
        url(
            host: "focus",
            path: "/start",
            queryItems: preset.map {
                [URLQueryItem(name: minutesQueryName, value: String($0.minutes))]
            }
        )
    }

    static func route(for url: URL) -> AppEntryRoute? {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
              components.scheme?.lowercased() == scheme,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let host = components.host?.lowercased()
        else { return nil }
        let path = components.path == "/" ? "" : components.path
        let queryItems = components.queryItems ?? []

        switch (host, path) {
        case ("home", ""):
            return queryItems.isEmpty ? .home : nil
        case ("focus", "/start"):
            if queryItems.isEmpty { return .startFocus(nil) }
            guard queryItems.count == 1,
                  let item = queryItems.first,
                  item.name == minutesQueryName,
                  let text = item.value,
                  text.allSatisfy(\.isASCII),
                  let minutes = Int(text),
                  let preset = FocusStartPreset(minutes: minutes)
            else { return nil }
            return .startFocus(preset)
        default:
            return nil
        }
    }

    private static func url(
        host: String,
        path: String,
        queryItems: [URLQueryItem]?
    ) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else {
            preconditionFailure("A constant pomogem:// route must form a URL")
        }
        return url
    }
}
