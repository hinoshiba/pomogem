#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Exercises the shipping choice and confirmation views without installing a
/// transfer runtime or calling a persistence, account, or CloudKit service.
enum StorageTransferSettingsUITestFixture {
    private static let environmentKey = "POMOGEM_UI_TEST_STORAGE_TRANSFER"

    enum Scenario: String {
        case offlineNavigation, offlineNavigationRecovered, offlineBreakNavigation, local, cloud, offline, offlineRecovery, offlineHistory, cloudNetworkWaiting, cloudLaunchTimedOut, activeTimer, exporting, deleting, unavailable
        /// Cloud mode with the Settings dataset doors PUBLISHED, so their
        /// consent flow can be exercised. `cloud` is the shipping screen, where
        /// the same doors render disabled with their reason.
        case cloudDatasetDoors
        /// The same published doors, but the read-only pre-flight fails. The
        /// device -> iCloud door must then stay shut with its own message:
        /// 「we could not look」 and 「there is nothing there」 must not be
        /// confusable before a deletion.
        case cloudDatasetDoorsUnreadable
        /// The launch-host screens a fenced device actually lands on. Each one
        /// renders the shipping `PersistenceLaunchStatusView` with a recorder in
        /// place of the runtime, so no journal, container or CloudKit call
        /// exists in the process.
        case datasetRefreshChoice, datasetRefreshOtherDevices, datasetRefreshPreviewFailed
        case datasetRefreshBlocked, overwriteInProgress
        /// `.remoteRecovery`, whose 「復旧を続ける」 door is gated by the resume
        /// bit — not by the legacy `allowsCloudReplacement`.
        case remoteResumeClosed, remoteResumeOpen
        /// PLAN Step 9 / §6.5. The non-blocking banner a committed device ->
        /// iCloud replacement raises when the one post-commit comparison finds
        /// user records the committed payload did not hold.
        case lateArrival

        var overwriteLaunch: StorageTransferOverwriteLaunchUITestScenario? {
            switch self {
            case .datasetRefreshChoice: .choice
            case .datasetRefreshOtherDevices: .otherDevices
            case .datasetRefreshPreviewFailed: .previewFailed
            case .datasetRefreshBlocked: .blocked
            case .overwriteInProgress: .inProgress
            case .remoteResumeClosed: .remoteResumeClosed
            case .remoteResumeOpen: .remoteResumeOpen
            default: nil
            }
        }

        var isOffline: Bool { self == .offline || self == .offlineRecovery || self == .offlineHistory }
        var recoveryKind: CloudOfflineRecoveryKind? {
            switch self {
            case .offlineRecovery: .storageTransfer
            case .offlineHistory: .resetHistory
            default: nil
            }
        }

        var mode: PersistenceLaunchMode {
            self == .cloud || self == .cloudDatasetDoors
                || self == .cloudDatasetDoorsUnreadable || self == .lateArrival || isOffline
                || self == .cloudNetworkWaiting ? .cloudKit : .localOnly
        }

        /// Exactly one bit, and only for the one scenario that exercises a
        /// published door. The legacy `localOnly -> cloud` replacement and the
        /// remote resume stay closed, so a fixture can never widen the shipping
        /// prohibition it is meant to exercise around.
        var releasePolicy: StorageTransferReleasePolicy {
            self == .cloudDatasetDoors || self == .cloudDatasetDoorsUnreadable
                ? .isolatedTestingPolicy(allowsDatasetOverwriteFromDevice: true)
                : .standard
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
    @State private var datasetCalls = 0
    @State private var lastDatasetDirection = "none"
    @State private var previewCalls = 0
    @State private var lateArrivalSettingsCalls = 0
    @State private var showsLateArrival = true
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
        } else if let overwrite = scenario.overwriteLaunch {
            StorageTransferOverwriteLaunchUITestFixtureView(scenario: overwrite)
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
                        Text(verbatim: "dataset=\(lastDatasetDirection);datasetCalls=\(datasetCalls)")
                            .accessibilityIdentifier("storage-switch.dataset-fixture-state")
                        Text(verbatim: "previewCalls=\(previewCalls)")
                            .accessibilityIdentifier("storage-switch.preview-fixture-state")
                        if scenario == .lateArrival {
                            Text(verbatim: "settingsCalls=\(lateArrivalSettingsCalls);shown=\(showsLateArrival)")
                                .accessibilityIdentifier("storage-overwrite.late-arrival-fixture-state")
                        }
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
                        otherWorkIsActive: scenario.otherWorkIsActive,
                        releasePolicy: scenario.releasePolicy
                    )
                }
                .navigationTitle("設定")
            }
        }
        .environment(\.isCloudOfflineSession, scenario.isOffline)
        .environment(\.cloudConnectionPresentation, presentation(scenario))
        .environment(\.storageTransferLateArrival, lateArrival(scenario))
        .task {
            guard scenario != .unavailable else { return }
            controller.install({ choice in
                calls += 1
                lastChoice = choice.rawValue
                // The accepted fake request stays busy while the test inspects
                // the UI. No operation performs a save or a source change.
                try await Task.sleep(for: .seconds(45))
            }, dataset: { direction in
                // Records the direction only. Nothing writes a dataset request
                // file, reads CloudKit, or asks for a relaunch in this process.
                datasetCalls += 1
                lastDatasetDirection = direction.rawValue
                try await Task.sleep(for: .seconds(45))
            }, datasetPreview: {
                // Stands in for the read-only server snapshot. It records that
                // it was asked, so a test can prove the evidence is gathered
                // BEFORE the acknowledgement rather than after it.
                previewCalls += 1
                guard scenario != .cloudDatasetDoorsUnreadable else {
                    throw CloudStorageTransferCloudError.timedOut
                }
                return Self.previewSummary
            })
        }
    }

    /// Two sides whose counts and dates differ, and one witnessed other
    /// device, so the sheet's comparison and evidence are both non-trivial.
    private static let previewSummary = StorageTransferDatasetPreviewSummary(
        cloud: preview(subjects: 9, sessions: 312, stones: 28,
                       year: 2026, month: 9, day: 18, otherDeviceIDs: 2),
        device: preview(subjects: 12, sessions: 480, stones: 36,
                        year: 2026, month: 9, day: 20, otherDeviceIDs: 0))

    private static func preview(subjects: Int, sessions: Int, stones: Int,
                                year: Int, month: Int, day: Int,
                                otherDeviceIDs: Int) -> StorageTransferCloudPreview {
        var counts = Dictionary(uniqueKeysWithValues:
            PomoGemStorageSnapshot.cloudModelNames.map { ($0, 0) })
        counts["Subject"] = subjects
        counts["StudySession"] = sessions
        counts["AchievementStone"] = stones
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return StorageTransferCloudPreview(
            recordCounts: counts,
            latestRecordAt: calendar.date(from: components),
            otherDeviceIDs: otherDeviceIDs, ignoredWriterIDs: 0)
    }

    /// Neither action touches data: 「このまま使う」 only hides the banner, and
    /// 「設定を開く」 only navigates. The recorder proves exactly that.
    private func lateArrival(
        _ scenario: StorageTransferSettingsUITestFixture.Scenario
    ) -> StorageTransferLateArrivalPresentation? {
        guard scenario == .lateArrival, showsLateArrival else { return nil }
        return StorageTransferLateArrivalPresentation(
            sessionID: fixtureSessionID, models: ["StudySession", "Subject"],
            dismiss: { showsLateArrival = false },
            openSettings: { lateArrivalSettingsCalls += 1 })
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
