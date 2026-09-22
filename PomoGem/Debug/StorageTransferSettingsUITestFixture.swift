#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Exercises the shipping choice and confirmation views without installing a
/// transfer runtime or calling a persistence, account, or CloudKit service.
enum StorageTransferSettingsUITestFixture {
    private static let environmentKey = "POMOGEM_UI_TEST_STORAGE_TRANSFER"

    enum Scenario: String {
        case offlineNavigation, offlineNavigationRecovered, offlineBreakNavigation, local, cloud, offline, offlineRecovery, offlineHistory, cloudNetworkWaiting, cloudLaunchTimedOut, activeTimer, exporting, deleting, unavailable

        var isOffline: Bool { self == .offline || self == .offlineRecovery || self == .offlineHistory }
        var recoveryKind: CloudOfflineRecoveryKind? {
            switch self {
            case .offlineRecovery: .storageTransfer
            case .offlineHistory: .resetHistory
            default: nil
            }
        }

        var mode: PersistenceLaunchMode {
            self == .cloud || isOffline || self == .cloudNetworkWaiting ? .cloudKit : .localOnly
        }
        var otherWorkIsActive: Bool {
            isOffline || self == .cloudNetworkWaiting || self == .activeTimer || self == .exporting || self == .deleting
        }
    }

    static var scenario: Scenario? {
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
              LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess == .inMemoryPreview,
              let value = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        return Scenario(rawValue: value)
    }

    static var isActiveForCurrentProcess: Bool { scenario != nil }
}

struct StorageTransferSettingsUITestFixtureLaunchView: View {
    @State private var controller = StorageTransferController()
    @State private var calls = 0
    @State private var lastChoice = "none"
    @State private var offlineRetryCalls = 0
    @State private var recoveryReviewCalls = 0
    @State private var isCheckingOfflineConnection = false
    @State private var fixtureSessionID = UUID()

    var body: some View {
        if let scenario = StorageTransferSettingsUITestFixture.scenario {
            content(scenario)
                .dynamicTypeSize(LocalPreviewLaunchPolicy.forcesAccessibility5(
                    environment: ProcessInfo.processInfo.environment,
                    isDebugBuild: true
                ) ? .accessibility5 : .large)
        }
    }

    @ViewBuilder
    private func content(_ scenario: StorageTransferSettingsUITestFixture.Scenario) -> some View {
        if scenario == .offlineNavigation || scenario == .offlineNavigationRecovered || scenario == .offlineBreakNavigation {
            CloudOfflineNavigationUITestFixtureView(
                preservesFocusRecovery: scenario == .offlineNavigationRecovered,
                startsRecoveredBreak: scenario == .offlineBreakNavigation)
        } else if scenario == .cloudLaunchTimedOut {
            CloudLaunchTimeoutUITestFixtureView()
        } else {
            settingsContent(scenario)
        }
    }

    private func settingsContent(_ scenario: StorageTransferSettingsUITestFixture.Scenario) -> some View {
        CloudConnectionSessionContent {
            NavigationStack {
                List {
                    Section {
                        Text(verbatim: "calls=\(calls);choice=\(lastChoice);starting=\(controller.isStarting)")
                            .accessibilityIdentifier("storage-switch.fixture-state")
                        if scenario.isOffline {
                            Text(verbatim: "retryCalls=\(offlineRetryCalls);checking=\(isCheckingOfflineConnection)")
                                .accessibilityIdentifier("cloud-offline.fixture-state")
                            Text(verbatim: "reviewCalls=\(recoveryReviewCalls)")
                                .accessibilityIdentifier("cloud-offline.recovery-fixture-state")
                        }
                    }
                    if scenario.isOffline {
                        CloudSyncSettingsSection(persistenceMode: .cloudKit)
                    }
                    StorageTransferSettingsSection(
                        persistenceMode: scenario.mode,
                        controller: controller,
                        otherWorkIsActive: scenario.otherWorkIsActive
                    )
                }
                .navigationTitle("設定")
            }
        }
        .environment(\.isCloudOfflineSession, scenario.isOffline)
        .environment(\.cloudConnectionPresentation, presentation(scenario))
        .task {
            guard scenario != .unavailable else { return }
            controller.install { choice in
                calls += 1
                lastChoice = choice.rawValue
                // The accepted fake request stays busy while the test inspects
                // the UI. No operation performs a save or a source change.
                try await Task.sleep(for: .seconds(45))
            }
        }
    }

    private func presentation(_ scenario: StorageTransferSettingsUITestFixture.Scenario) -> CloudConnectionPresentation? {
        if scenario.isOffline {
            return CloudConnectionPresentation(sessionID: fixtureSessionID, isChecking: isCheckingOfflineConnection,
                message: "通信を確認できないため、端末のデータで利用を続けています。変更は端末に保存されます。",
                retry: {
                    // Keep the simulated request in flight until this
                    // fixture disappears. The real Banner's disabled state
                    // must prevent subsequent taps from calling us again.
                    offlineRetryCalls += 1
                    isCheckingOfflineConnection = true
                }, recoveryKind: scenario.recoveryKind, reviewRecovery: scenario == .offlineRecovery ? {
                    guard recoveryReviewCalls == 0 else { return }
                    recoveryReviewCalls += 1
                    isCheckingOfflineConnection = true
                } : nil)
        } else if scenario == .cloudNetworkWaiting {
            // Only the production banner's native-mirroring presentation
            // is exercised here. No monitor, network, or store is started.
            return CloudConnectionPresentation(sessionID: fixtureSessionID, isChecking: false,
                message: "通信の回復を待っています。端末への記録は続けられます。", retry: nil)
        }
        return nil
    }
}

/// The real Root, Home, destinations, and full-screen timers share precisely
/// the production Host wrapper. Only transport is replaced by a call recorder;
/// the inherited store is the explicitly opted-in in-memory UI-test store.
private struct CloudOfflineNavigationUITestFixtureView: View {
    let preservesFocusRecovery: Bool
    let startsRecoveredBreak: Bool
    @State private var sessionID = UUID()
    @State private var retryCalls = 0
    @State private var isPrepared = false

    var body: some View {
        Group {
            if isPrepared {
                CloudConnectionSessionContent {
                    RootView(persistenceStartupError: nil)
                }
                .environment(\.isCloudOfflineSession, true)
                .environment(\.cloudConnectionPresentation, CloudConnectionPresentation(
                    sessionID: sessionID, isChecking: retryCalls > 0,
                    message: "端末のデータで利用しています。retryCalls=\(retryCalls)",
                    retry: { retryCalls += 1 }))
            } else {
                ProgressView()
            }
        }
        .task {
            guard !isPrepared else { return }
            // UI-test recovery uses UserDefaults rather than the in-memory
            // store. Clear only this opted-in simulator fixture's old timer.
            if !preservesFocusRecovery {
                FocusPersistence.clear()
                FocusPersistence.clearBreak()
            }
            if startsRecoveredBreak {
                FocusPersistence.saveBreak(BreakRecoveryEnvelope(
                    id: UUID(), minutes: 5, endDate: .now.addingTimeInterval(300)))
            }
            isPrepared = true
        }
    }
}
#endif
