#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Exercises the shipping choice and confirmation views without installing a
/// transfer runtime or calling a persistence, account, or CloudKit service.
enum StorageTransferSettingsUITestFixture {
    private static let environmentKey = "POMOGEM_UI_TEST_STORAGE_TRANSFER"

    enum Scenario: String {
        case local, cloud, offline, offlineRecovery, offlineHistory, cloudNetworkWaiting, activeTimer, exporting, deleting, unavailable

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

    var body: some View {
        if let scenario = StorageTransferSettingsUITestFixture.scenario {
            content(scenario)
                .dynamicTypeSize(LocalPreviewLaunchPolicy.forcesAccessibility5(
                    environment: ProcessInfo.processInfo.environment,
                    isDebugBuild: true
                ) ? .accessibility5 : .large)
        }
    }

    private func content(_ scenario: StorageTransferSettingsUITestFixture.Scenario) -> some View {
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
        .environment(\.isCloudOfflineSession, scenario.isOffline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if scenario.isOffline {
                CloudOfflineBanner(isChecking: isCheckingOfflineConnection,
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
                CloudOfflineBanner(isChecking: false,
                    message: "通信の回復を待っています。端末への記録は続けられます。", retry: nil)
            }
        }
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
}
#endif
