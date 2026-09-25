import Foundation

extension AppRouter {
    /// The raw-stone widget's link (`StartFocusLink`, D19): show Home, the
    /// start screen with the focus button. Navigation only — nothing starts,
    /// nothing is read or written, and an open sheet stays where it is.
    /// Returns whether the URL was the start link.
    @discardableResult
    func openStartLink(_ url: URL) -> Bool {
        guard StartFocusLink.matches(url) else { return false }
        selectedTab = .jar
        return true
    }
}
