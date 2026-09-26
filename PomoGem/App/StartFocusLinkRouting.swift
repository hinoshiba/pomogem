import Foundation

extension AppRouter {
    /// The raw-stone widget's link (`StartFocusLink`, D19): it brings the
    /// app forward, where a launch opens on Home, the start screen with the
    /// focus button. Nothing starts, nothing is read or written, and — since
    /// round 12 — nothing the person left open is closed: a page pushed from
    /// Home (Settings, 記録, Screen Time) stays, because popping it would
    /// dismiss its sheets and drop an unsaved edit or an export in flight.
    /// Any app (or a web page, after iOS asks) can open this URL, so it must
    /// never cost the person work. Returns whether the URL was the start
    /// link.
    @discardableResult
    func openStartLink(_ url: URL) -> Bool {
        StartFocusLink.matches(url)
    }
}
