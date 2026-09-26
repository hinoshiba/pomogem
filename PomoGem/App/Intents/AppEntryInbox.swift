import Foundation
import Observation

/// A focus start asked for from outside the app, handed from Root to Home.
struct PendingFocusStart: Identifiable, Equatable, Sendable {
    let id: UUID
    let preset: FocusStartPreset?
    /// `ContinuousUptime`, so a clock change cannot extend or cut the window.
    let receivedAtUptime: TimeInterval
}

/// Holds the one entry request (a widget tap, a `pomogem://` link or an App
/// Shortcut) that arrived before the app could act on it.
///
/// It lives for the whole process, not in `AppRouter`: a cold launch and every
/// iCloud return rebuild Root, and the request must survive the brief account
/// check in between. It never outlives that path, though. A request is kept
/// for at most `lifetime`, and the launch host drops it as soon as a stop
/// screen appears, so a start can never fire behind a fail-closed screen or
/// minutes later. Only Root takes it, and only once it shows the jar.
@MainActor
@Observable
final class AppEntryInbox {
    struct Request: Identifiable, Equatable, Sendable {
        let id = UUID()
        let route: AppEntryRoute
        let receivedAtUptime: TimeInterval
    }

    static let shared = AppEntryInbox()

    /// Long enough for a slow iCloud account check on launch; short enough
    /// that a request can never surprise someone who has moved on.
    nonisolated static let lifetime: TimeInterval = 60

    private(set) var pending: Request?

    init() {}

    /// Returns false for a URL that is not a `pomogem://` route.
    @discardableResult
    func receive(
        url: URL,
        uptime: TimeInterval = ContinuousUptime.now()
    ) -> Bool {
        guard let route = AppEntryLink.route(for: url) else { return false }
        receive(route, uptime: uptime)
        return true
    }

    /// The newest request replaces an older one: the last tap is what the
    /// person meant.
    func receive(
        _ route: AppEntryRoute,
        uptime: TimeInterval = ContinuousUptime.now()
    ) {
        pending = Request(route: route, receivedAtUptime: uptime)
    }

    /// Removes and returns the pending request if it is still fresh. An
    /// expired one is dropped silently.
    func take(uptime: TimeInterval = ContinuousUptime.now()) -> Request? {
        guard let request = pending else { return nil }
        pending = nil
        return Self.isFresh(request.receivedAtUptime, at: uptime) ? request : nil
    }

    func discard() {
        guard pending != nil else { return }
        pending = nil
    }

    nonisolated static func isFresh(
        _ receivedAtUptime: TimeInterval,
        at uptime: TimeInterval
    ) -> Bool {
        let age = uptime - receivedAtUptime
        return age.isFinite && age >= 0 && age <= lifetime
    }
}
