import SwiftUI

/// quality-01 / launch-01. Where the person was when an iCloud session had to
/// be closed, so the next mount of the SAME account's data opens there again.
///
/// A session that outlives the background grace is retired, and the next one
/// is a new RootView with a new router: before this, a trip to iOS Settings
/// from the in-app 「設定を開く」 always came back to the jar. Only the tab is
/// remembered (jar / 記録 / 設定) — never a sheet, a recovered focus, a share
/// scope or anything read from the store — and only inside this process.
enum CloudRemountNavigationPolicy {
    struct Saved: Equatable, Sendable {
        let namespace: AccountDataNamespace
        let tab: AppTab
    }

    /// The tab a fresh Root may open on. Nothing is restored across account
    /// namespaces, and nothing without a namespace to compare.
    static func restoredTab(saved: Saved?, mountedNamespace: AccountDataNamespace?) -> AppTab? {
        guard let saved, let mountedNamespace, saved.namespace == mountedNamespace else { return nil }
        return saved.tab
    }
}

/// Host-owned and process-local. The host clears it on any possible account
/// change and on a storage-transfer relaunch; a mismatching namespace also
/// discards it on first use.
@MainActor
final class CloudRemountNavigationMemory {
    private var saved: CloudRemountNavigationPolicy.Saved?

    func record(_ tab: AppTab, namespace: AccountDataNamespace?) {
        guard let namespace else { return }
        saved = .init(namespace: namespace, tab: tab)
    }

    /// One use per remount: the value is consumed whether or not it matched.
    func takeRestoredTab(for namespace: AccountDataNamespace?) -> AppTab? {
        defer { saved = nil }
        return CloudRemountNavigationPolicy.restoredTab(saved: saved, mountedNamespace: namespace)
    }

    func clear() {
        saved = nil
    }
}

/// What one mounted session's Root sees: the shared memory, bound to that
/// session's namespace so Root never has to know which account it shows.
struct CloudRemountNavigationHandle {
    let memory: CloudRemountNavigationMemory
    let namespace: AccountDataNamespace?

    @MainActor func record(_ tab: AppTab) {
        memory.record(tab, namespace: namespace)
    }

    @MainActor func takeRestoredTab() -> AppTab? {
        memory.takeRestoredTab(for: namespace)
    }
}

private struct CloudRemountNavigationKey: EnvironmentKey {
    static let defaultValue: CloudRemountNavigationHandle? = nil
}

extension EnvironmentValues {
    var cloudRemountNavigation: CloudRemountNavigationHandle? {
        get { self[CloudRemountNavigationKey.self] }
        set { self[CloudRemountNavigationKey.self] = newValue }
    }
}
