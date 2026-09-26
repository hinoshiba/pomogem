#if DEBUG
import Foundation

/// Keeps a Debug launch's UserDefaults consistent with the SwiftData store it
/// opens.
///
/// A local preview (every UI test that sets `POMOGEM_LOCAL_PREVIEW`, and a
/// developer's preview run) opens a new, empty in-memory store, and a UI test
/// can ask for a named fixture store it has just created or cleaned. The small
/// queues below live in UserDefaults instead, and the Simulator keeps those
/// across launches. An entry left by an earlier or interrupted launch names a
/// StudySession the new store never had, and Home cannot resolve it: a reward
/// receipt waiting for its drop keeps the start button disabled for the rest
/// of the run, and a leftover rest cadence turns the first 「5分休憩する」 into
/// a long break. Every item here is derived from rows of the store it was
/// written with, so it is stale by construction when that store is new.
///
/// Timer state (a running or pending focus, a break) is kept on purpose: it
/// does not point at store rows, and relaunch tests rely on it surviving.
///
/// Production never calls this, and Release does not contain it. Real stores
/// persist, so these queues always describe rows that still exist, and a
/// reset or complete deletion clears them with the rows.
enum UITestLocalStateIsolation {
    static func forgetStateDerivedFromPreviousStores(
        defaults: UserDefaults = .standard
    ) {
        PendingRewardReceiptStore.removeAll(defaults: defaults)
        PendingStratumCelebrationStore.removeAll(defaults: defaults)
        ScreenTimeGemDropStore.removeAll(defaults: defaults)
        FocusRestCadenceStore.removeAll(defaults: defaults)
        defaults.removeObject(forKey: FocusPersistence.localCompletionIDKey)
    }
}
#endif
