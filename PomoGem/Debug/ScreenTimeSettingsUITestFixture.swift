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
    /// One more than `FocusShieldPolicy.maximumApplications`.
    static let tooManyDistractionApplicationCount = 51

    /// The scenarios whose fixture bar can start a focus.
    static var drivesFocusShield: Bool {
        scenario == .focusShield || scenario == .focusShieldTooManyApps
    }

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
        /// F2: a bound, approved owner with the seeded apps and the focus
        /// shield switched off. The fixture bar can start a focus, which
        /// reconciles the shield through the real `FocusShieldController`
        /// and `FocusShieldEngine` over in-memory ManagedSettings and
        /// DeviceActivity doubles, and can make the failsafe refuse.
        case focusShield = "focus-shield"
        /// F2: the shield switched on with more distraction apps than a
        /// shield can hold, so the page must say it shields nothing.
        case focusShieldTooManyApps = "focus-shield-too-many"
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

    static func tooManyAppsConfiguration(themeID: UUID) -> ScreenTimeConfiguration {
        var configuration = ScreenTimeConfiguration()
        configuration.enabled = true
        configuration.themeID = themeID
        configuration.distractionSelection.applicationTokens =
            applicationTokens(count: tooManyDistractionApplicationCount, seed: 0x33)
        configuration.shieldsDistractionDuringFocusEnabled = true
        return configuration
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
    private var refuses = false

    /// Makes every later `startMonitoring` throw, as a real center does when
    /// it rejects a schedule, so the focus shield's failsafe-unavailable
    /// path can be seen.
    var refusesRegistration: Bool {
        get { lock.lock(); defer { lock.unlock() }; return refuses }
        set { lock.lock(); defer { lock.unlock() }; refuses = newValue }
    }

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
        if refuses { throw ScreenTimeError.unavailable }
        names.insert(activity.rawValue)
    }
}

/// Stands in for the named ManagedSettings store: remembers how many apps
/// the focus shield would block right now. The Simulator cannot shield.
private final class ScreenTimeSettingsUITestFixtureShieldSettings: FocusShieldSettingsDriving {
    private let lock = NSLock()
    private var count = 0

    var shieldedApplicationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func shield(applications: Set<ApplicationToken>) {
        lock.lock()
        defer { lock.unlock() }
        count = applications.count
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        count = 0
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
final class ScreenTimeSettingsUITestFixtureModel: ObservableObject {
    let controller: ScreenTimeController
    /// Focus starts and ends whose shield work has fully run. The ledger row
    /// prints it, so a test can wait for a pass to finish before it reads
    /// the record: a pass that changes nothing publishes nothing on either
    /// controller, and the row would otherwise still show the old ledger.
    @Published private(set) var focusPasses = 0
    let themeID = UUID()
    private let store: ScreenTimeStore
    private let directory: URL
    private let driver: ScreenTimeSettingsUITestFixtureDriver
    private let shieldRecords: FocusShieldRecordStore
    private let shieldSettings: ScreenTimeSettingsUITestFixtureShieldSettings
    private let shieldCenter: ScreenTimeSettingsUITestFixtureCenter
    private lazy var seeded = ScreenTimeSettingsUITestFixture.seededConfiguration(themeID: themeID)

    init(scenario: ScreenTimeSettingsUITestFixture.Scenario) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenTimeSettingsUITestFixture-\(UUID().uuidString)", isDirectory: true)
        store = ScreenTimeStore(directory: directory)
        driver = ScreenTimeSettingsUITestFixtureDriver(store: store)
        let records = FocusShieldRecordStore(directory: store.directoryURL)
        let settings = ScreenTimeSettingsUITestFixtureShieldSettings()
        let center = ScreenTimeSettingsUITestFixtureCenter()
        shieldRecords = records
        shieldSettings = settings
        shieldCenter = center
        let refused = scenario == .authorizationRefused
        // The real controller and engine over doubles: the record is a real
        // file next to this temporary ledger, and nothing reaches the named
        // ManagedSettings store or DeviceActivityCenter.
        let focusShield = FocusShieldController(engine: FocusShieldEngine(
            records: records, settings: settings, center: center
        ))
        controller = ScreenTimeController(
            store: store,
            currentContextKey: { ScreenTimeSettingsUITestFixture.ownerKey },
            monitoring: driver,
            authorization: { refused ? .notDetermined : .approved },
            requestIndividualAuthorization: {
                if refused { throw FamilyControlsError.authenticationMethodUnavailable }
            },
            focusShield: focusShield
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
            switch scenario {
            case .lateBinding:
                state.configuration = seeded
                state.negativeGemCount = ScreenTimeSettingsUITestFixture.negativeGemCount
            case .focusShield:
                state.configuration = seeded
            case .focusShieldTooManyApps:
                state.configuration = ScreenTimeSettingsUITestFixture.tooManyAppsConfiguration(themeID: themeID)
            case .firstSetup, .authorizationRefused:
                break
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

    /// What the settings page's host does when a focus starts or resumes on
    /// this iPhone: reconcile the shield for a running focus that ends in
    /// 25 minutes. A new session each time, so a lifted one does not stay
    /// lifted.
    func startFocus() {
        reconcileFocus(.running(sessionID: UUID(), plannedEnd: Date().addingTimeInterval(25 * 60)))
    }

    /// What the host does when the focus completes or is abandoned.
    func endFocus() {
        reconcileFocus(.none)
    }

    private func reconcileFocus(_ focus: FocusShieldFocusState) {
        controller.focusShield.reconcile(
            configuration: controller.configuration, authorization: .approved, focus: focus, force: true
        )
        Task {
            await controller.focusShield.waitForPendingOperations()
            focusPasses += 1
        }
    }

    func refuseFailsafeRegistration() {
        shieldCenter.refusesRegistration = true
    }

    private var shieldRecordSummary: String {
        guard let record = try? shieldRecords.load() else { return "none" }
        if record.active { return "active" }
        return record.liftedAt == nil ? "cleared" : "lifted"
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
            "sync=\(driver.events.filter { $0 == "synchronize" }.count)",
            "focusShield=\(state.configuration.shieldsDistractionDuringFocusEnabled ? 1 : 0)",
            "shieldRecord=\(shieldRecordSummary)",
            "shielded=\(shieldSettings.shieldedApplicationCount)"
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
    @ObservedObject var model: ScreenTimeSettingsUITestFixtureModel
    /// Observed so the row re-reads the ledger whenever the controller
    /// publishes — a bind, a save, or a refused save.
    @ObservedObject var controller: ScreenTimeController
    let bindState: String
    let bind: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FixtureLedgerRow(model: model, controller: controller, shield: controller.focusShield,
                             bindState: bindState)
            HStack(spacing: 16) {
                Button("fixture-bind") { bind() }
                    .disabled(bindState != "unbound")
                    .accessibilityIdentifier("screen-time.fixture-bind")
                if ScreenTimeSettingsUITestFixture.drivesFocusShield {
                    Button("fixture-start-focus") { model.startFocus() }
                        .accessibilityIdentifier("screen-time.fixture-start-focus")
                    Button("fixture-end-focus") { model.endFocus() }
                        .accessibilityIdentifier("screen-time.fixture-end-focus")
                    Button("fixture-refuse-failsafe") { model.refuseFailsafeRegistration() }
                        .accessibilityIdentifier("screen-time.fixture-refuse-failsafe")
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.regularMaterial)
        // A test readout, not app UI: at AX5 it would cover half the page.
        .dynamicTypeSize(.large)
    }
}

/// The ledger readout. Observes the focus shield as well as the Screen Time
/// controller: a shield operation publishes only on `FocusShieldController`,
/// and only when `isShielding` or `failsafeUnavailable` changes, which for a
/// lift happens before the queued operation has written the record. So the
/// row also re-reads once the shield's queue has drained after each change,
/// and after every fixture focus start or end (`focusPasses`), which may
/// change nothing that is published at all.
private struct FixtureLedgerRow: View {
    @ObservedObject var model: ScreenTimeSettingsUITestFixtureModel
    @ObservedObject var controller: ScreenTimeController
    @ObservedObject var shield: FocusShieldController
    let bindState: String
    @State private var drainedPasses = 0

    var body: some View {
        Text(verbatim: "bind=\(bindState);boundToContext=\(controller.isBoundToContext);"
             + "\(model.ledgerSummary);isShielding=\(shield.isShielding ? 1 : 0);"
             + "failsafeUnavailable=\(shield.failsafeUnavailable ? 1 : 0);"
             + "lastFocusUnshielded=\(shield.lastFocusWentUnshielded ? 1 : 0);"
             + "focusPasses=\(model.focusPasses);drained=\(drainedPasses)")
            .font(.caption2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("screen-time.fixture-ledger")
            .task(id: "\(shield.isShielding)-\(shield.failsafeUnavailable)") {
                await shield.waitForPendingOperations()
                drainedPasses += 1
            }
    }
}
#endif
