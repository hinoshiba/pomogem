#if DEBUG && targetEnvironment(simulator)
import DeviceActivity
import FamilyControls
import ManagedSettings
import SwiftData
import SwiftUI

/// Gives the unbound → bound draft re-seed the only automated coverage the
/// Simulator can produce.
///
/// A Simulator build carries no entitlements, so
/// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` is nil,
/// `ScreenTimeController.shared` can never bind, and `isBoundToContext` never
/// leaves `false` — the half of F4 that actually protects the stored opaque
/// selections is therefore unreachable through the shipping screen. This
/// fixture points ONE settings screen at a private controller backed by a
/// temporary-directory ledger, with the authorization status stubbed and a
/// recording double in place of `ScreenTimeMonitoring`. Nothing here touches
/// `ScreenTimeController.shared`, the App Group, DeviceActivity or the monitor
/// extension, and the whole file is compiled out of Release and of every
/// device build.
enum ScreenTimeSettingsUITestFixture {
    static let environmentKey = "POMOGEM_UI_TEST_SCREEN_TIME"
    /// Deliberately not `AccountScopedLocalState.defaultsKey(base:)`: the
    /// fixture ledger must never be mistaken for a real owner's.
    static let ownerKey = "screen-time-uitest-owner"
    static let themeName = "スクリーンタイム検証テーマ"
    static let learningApplicationCount = 2
    static let distractionApplicationCount = 1
    static let negativeGemCount = 3

    enum Scenario: String {
        /// The settings screen appears while the controller is still unbound;
        /// the ledger admits the owner only when the test says so.
        case lateBinding = "late-binding"
        /// A bound owner that never set anything up, with one theme. The
        /// settings screen is pushed from a root screen so going back — and
        /// the unsaved-changes question it asks — can be exercised.
        case firstSetup = "first-setup"
        /// A bound owner without access whose request Family Controls
        /// refuses for want of a passcode, so the refusal, its fix and the
        /// Settings shortcut can be seen. The Simulator cannot refuse itself.
        case authorizationRefused = "authorization-refused"
    }

    static var scenario: Scenario? {
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
              LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess == .inMemoryPreview,
              let value = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        return Scenario(rawValue: value)
    }

    static var isActiveForCurrentProcess: Bool { scenario != nil }

    /// Synthetic opaque values that stay inside this process's temporary
    /// ledger. `FamilyActivityPicker` is never opened and Family Controls is
    /// never asked for a token, exactly as in the Screen Time unit tests.
    static func applicationTokens(count: Int, seed: UInt8) -> Set<ApplicationToken> {
        var tokens: Set<ApplicationToken> = []
        for index in 0..<count {
            guard let token = try? JSONDecoder().decode(
                ApplicationToken.self,
                from: JSONEncoder().encode(["data": Data([seed, UInt8(index)])])
            ) else { continue }
            tokens.insert(token)
        }
        return tokens
    }

    static func seededConfiguration(themeID: UUID) -> ScreenTimeConfiguration {
        var configuration = ScreenTimeConfiguration()
        configuration.enabled = true
        configuration.themeID = themeID
        configuration.learningSelection.applicationTokens =
            applicationTokens(count: learningApplicationCount, seed: 0x11)
        configuration.distractionSelection.applicationTokens =
            applicationTokens(count: distractionApplicationCount, seed: 0x22)
        return configuration
    }
}

/// Stands in for DeviceActivityCenter: keeps the registered names in memory
/// and never calls the OS.
private final class ScreenTimeSettingsUITestFixtureCenter: ScreenTimeActivityCenterDriving {
    private let lock = NSLock()
    private var names: Set<String> = []

    var activities: [DeviceActivityName] {
        lock.lock()
        defer { lock.unlock() }
        return names.map(DeviceActivityName.init(rawValue:))
    }

    func stopMonitoring(_ activities: [DeviceActivityName]) {
        lock.lock()
        defer { lock.unlock() }
        if activities.isEmpty { names.removeAll() } else { names.subtract(activities.map(\.rawValue)) }
    }

    func startMonitoring(
        _ activity: DeviceActivityName,
        during schedule: DeviceActivitySchedule,
        events: [DeviceActivityEvent.Name: DeviceActivityEvent]
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        names.insert(activity.rawValue)
    }
}

/// Records what the controller asks of DeviceActivity and runs the real
/// `ScreenTimeMonitoring` against an in-memory center, so a save produces the
/// same runs — and the same 自動記録中 — it would on a device. The worker
/// invokes these off the main thread, like the real driver.
private final class ScreenTimeSettingsUITestFixtureDriver: ScreenTimeMonitoringDriving {
    private let lock = NSLock()
    private var calls: [String] = []
    private let monitoring: ScreenTimeMonitoring

    init(store: ScreenTimeStore) {
        monitoring = ScreenTimeMonitoring(
            store: store, center: ScreenTimeSettingsUITestFixtureCenter(), authorization: { true }
        )
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    private func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        calls.append(event)
    }

    func stop() {
        record("stop")
        monitoring.stop()
    }
    func invalidateAuthorizationIfNeeded() throws { record("invalidate") }
    func synchronize(now: Date) throws -> Bool {
        record("synchronize")
        return try monitoring.synchronize(now: now)
    }
}

@MainActor
final class ScreenTimeSettingsUITestFixtureModel {
    let controller: ScreenTimeController
    let themeID = UUID()
    private let store: ScreenTimeStore
    private let directory: URL
    private let driver: ScreenTimeSettingsUITestFixtureDriver
    private lazy var seeded = ScreenTimeSettingsUITestFixture.seededConfiguration(themeID: themeID)

    init(scenario: ScreenTimeSettingsUITestFixture.Scenario) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTimeSettingsUITestFixture-\(UUID().uuidString)", isDirectory: true)
        store = ScreenTimeStore(directory: directory)
        driver = ScreenTimeSettingsUITestFixtureDriver(store: store)
        let refused = scenario == .authorizationRefused
        controller = ScreenTimeController(
            store: store,
            currentContextKey: { ScreenTimeSettingsUITestFixture.ownerKey },
            monitoring: driver,
            authorization: { refused ? .notDetermined : .approved },
            requestIndividualAuthorization: {
                if refused { throw FamilyControlsError.authenticationMethodUnavailable }
            }
        )
    }

    /// Writes the ledger a previously bound owner would have left behind, plus
    /// the theme its `themeID` points at. Both exist BEFORE the settings screen
    /// mounts, so the screen's first draft can only come from the still-empty
    /// published configuration.
    func prepare(into context: ModelContext, scenario: ScreenTimeSettingsUITestFixture.Scenario) {
        try? store.update { state in
            state = ScreenTimeState()
            state.contextKey = ScreenTimeSettingsUITestFixture.ownerKey
            state.dataEpochID = nil
            state.contextIsActive = true
            state.learningAllowedBySubscription = true
            if scenario == .lateBinding {
                state.configuration = seeded
                state.negativeGemCount = ScreenTimeSettingsUITestFixture.negativeGemCount
            }
        }
        context.insert(Subject(
            id: themeID,
            name: ScreenTimeSettingsUITestFixture.themeName,
            colorHex: Constants.Color.english,
            sortOrder: 0
        ))
        try? context.save()
    }

    func bind() async throws {
        try await controller.bindContext(
            contextKey: ScreenTimeSettingsUITestFixture.ownerKey, dataEpochID: nil)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// What is actually on disk, independent of anything the screen publishes.
    /// `matchesSeed` is the assertion that matters: a save performed from a
    /// draft seeded off an unbound controller would replace the stored opaque
    /// tokens with an empty selection and flip it to false.
    var ledgerSummary: String {
        guard let state = try? store.snapshot() else { return "ledger=unreadable" }
        return [
            "learning=\(state.configuration.learningSelection.applicationTokens.count)",
            "distraction=\(state.configuration.distractionSelection.applicationTokens.count)",
            "enabled=\(state.configuration.enabled ? 1 : 0)",
            "theme=\(state.configuration.themeID == themeID ? "seed" : "other")",
            "matchesSeed=\(state.configuration == seeded)",
            "sync=\(driver.events.filter { $0 == "synchronize" }.count)"
        ].joined(separator: ";")
    }
}

struct ScreenTimeSettingsUITestFixtureLaunchView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var router = AppRouter()
    @State private var model: ScreenTimeSettingsUITestFixtureModel?
    @State private var bindState = "unbound"

    var body: some View {
        Group {
            if let model {
                NavigationStack {
                    if ScreenTimeSettingsUITestFixture.scenario == .firstSetup {
                        List {
                            NavigationLink("fixture-open-settings") {
                                ScreenTimeSettingsView(controller: model.controller)
                            }
                            .accessibilityIdentifier("screen-time.fixture-open")
                        }
                        .navigationTitle("fixture-root")
                    } else {
                        ScreenTimeSettingsView(controller: model.controller)
                    }
                }
                .overlay(alignment: .top) {
                    // The app draws toasts in RootView, which this fixture
                    // replaces; show them the same way so a test can read one.
                    if let toast = router.toast {
                        ToastOverlay(message: toast)
                            .accessibilityIdentifier("screen-time.fixture-toast")
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    ScreenTimeSettingsUITestFixtureBar(
                        model: model,
                        controller: model.controller,
                        bindState: bindState,
                        bind: { bind(model) }
                    )
                }
            } else {
                ProgressView()
            }
        }
        .environment(router)
        .dynamicTypeSize(LocalPreviewLaunchPolicy.forcesAccessibility5(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: true
        ) ? .accessibility5 : .large)
        .task {
            guard model == nil, let scenario = ScreenTimeSettingsUITestFixture.scenario else { return }
            let prepared = ScreenTimeSettingsUITestFixtureModel(scenario: scenario)
            prepared.prepare(into: modelContext, scenario: scenario)
            model = prepared
            if scenario != .lateBinding { bind(prepared) }
        }
        .onDisappear { model?.tearDown() }
    }

    /// The bind is driven by the test rather than a timer so the unbound window
    /// lasts exactly as long as the assertions need. What it exercises is the
    /// production transition: a real `bindContext` flips
    /// `ScreenTimeController.isBoundToContext` from false to true while the
    /// settings screen is already on screen.
    private func bind(_ model: ScreenTimeSettingsUITestFixtureModel) {
        guard bindState == "unbound" else { return }
        bindState = "binding"
        Task {
            do {
                try await model.bind()
                bindState = "bound"
            } catch {
                bindState = "failed"
            }
        }
    }
}

private struct ScreenTimeSettingsUITestFixtureBar: View {
    let model: ScreenTimeSettingsUITestFixtureModel
    /// Observed so the row re-reads the ledger whenever the controller
    /// publishes — a bind, a save, or a refused save.
    @ObservedObject var controller: ScreenTimeController
    let bindState: String
    let bind: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "bind=\(bindState);boundToContext=\(controller.isBoundToContext);\(model.ledgerSummary)")
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("screen-time.fixture-ledger")
            Button("fixture-bind") { bind() }
                .font(.caption)
                .disabled(bindState != "unbound")
                .accessibilityIdentifier("screen-time.fixture-bind")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.regularMaterial)
        // A test readout, not app UI: at AX5 it would cover half the page.
        .dynamicTypeSize(.large)
    }
}
#endif
