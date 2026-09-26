#if DEBUG
import Foundation

/// Keeps a Debug launch's UserDefaults consistent with the SwiftData store it
/// opens, and keeps one UI test's leftovers out of the next test.
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
/// Timer state (a running or pending focus, a break) survives a relaunch on
/// purpose, because relaunch tests recover it. It must not reach the next
/// test, though: a pending completion from a test that ended during its alarm
/// opens the next test on 「記録をまだ安全に保存できていません」 instead of
/// Home, because its synced timer row lived in the earlier store. Every
/// UI-test launch therefore names its test (`POMOGEM_UI_TEST_SCENARIO`, set by
/// `PomoGemUITestScenario` in the UI-test target). The first launch of a new
/// test forgets the timer state and the queues; the test's own relaunches
/// keep them. The app calls this only on the Simulator: device tests run
/// against the owner's real store and timer.
///
/// Production never calls this, and Release does not contain it. Real stores
/// persist, so these queues always describe rows that still exist, and a
/// reset or complete deletion clears them with the rows.
enum UITestLocalStateIsolation {
    static let scenarioEnvironmentKey = "POMOGEM_UI_TEST_SCENARIO"
    static let scenarioDefaultsKey = "ui-test.current-scenario"

    static func forgetStateDerivedFromPreviousStores(
        defaults: UserDefaults = .standard
    ) {
        PendingRewardReceiptStore.removeAll(defaults: defaults)
        PendingStratumCelebrationStore.removeAll(defaults: defaults)
        ScreenTimeGemDropStore.removeAll(defaults: defaults)
        FocusRestCadenceStore.removeAll(defaults: defaults)
        defaults.removeObject(forKey: FocusPersistence.localCompletionIDKey)
    }

    /// Call once per process, before anything reads the saved timer. Returns
    /// whether this launch starts a different UI test than the last launch.
    /// FocusPersistence reads and writes only `UserDefaults.standard`, so
    /// this does too.
    @discardableResult
    static func beginScenarioIfNeeded(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let defaults = UserDefaults.standard
        guard let scenario = environment[scenarioEnvironmentKey],
              !scenario.isEmpty,
              defaults.string(forKey: scenarioDefaultsKey) != scenario
        else { return false }
        FocusPersistence.clear()
        FocusPersistence.clearBreak(defaults: defaults)
        defaults.removeObject(forKey: FocusPersistence.interruptedFlagKey)
        TimerCompletionAlertAcknowledgementStore.removeAll(defaults: defaults)
        forgetStateDerivedFromPreviousStores(defaults: defaults)
        defaults.set(scenario, forKey: scenarioDefaultsKey)
        return true
    }
}
#endif
