#if DEBUG && targetEnvironment(simulator)
import SwiftUI

/// Exercises the shipping choice and confirmation views without installing a
/// transfer runtime or calling a persistence, account, or CloudKit service.
enum StorageTransferSettingsUITestFixture {
    private static let environmentKey = "POMOGEM_UI_TEST_STORAGE_TRANSFER"

    enum Scenario: String {
        case offlineNavigation, offlineNavigationRecovered, offlineBreakNavigation, local, cloud, offline, offlineRecovery, offlineHistory, cloudNetworkWaiting, cloudLaunchTimedOut, activeTimer, exporting, deleting, unavailable
        /// quality-01. The iCloud waiting screens with a running focus of the
        /// closed session behind them, shown as the account-neutral card.
        case cloudLaunchTimedOutWithFocus, cloudOfflineWallWithFocus, cloudBackgroundReturnWithFocus
        /// Cloud mode with the Settings dataset doors PUBLISHED, so their
        /// consent flow can be exercised. `cloud` is the shipping screen, where
        /// the same doors render disabled with their reason.
        case cloudDatasetDoors
        /// The same published doors, but the read-only pre-flight fails. The
        /// device -> iCloud door must then stay shut with its own message:
        /// 「we could not look」 and 「there is nothing there」 must not be
        /// confusable before a deletion.
        case cloudDatasetDoorsUnreadable
        /// W6. The same published doors for an account that has records in
        /// iCloud but NO transfer control record — the ordinary state of an
        /// account that was never transferred. The comparison names the
        /// absence and the device → iCloud confirmation says the operation
        /// starts a lineage rather than replacing one.
        case cloudDatasetDoorsNoLineage
        /// review-1-2 / review-2-4. The account whose iCloud side holds no
        /// PomoGem record at all — app data deleted from iOS Settings, a cause
        /// ROOT-CAUSE §6.2 names. Direction (B) would discard the device's only
        /// copy and mirror down nothing, so its confirmation must say so.
        case cloudDatasetDoorsEmptyCloud
        /// transfer-03, the shipping build. The server holds only what every
        /// account a device ever opened holds — five seeded preset themes, a
        /// Prefs writer row and a device claim — and none of the user's own
        /// records. The empty-iCloud warning must fire, and this iPhone's
        /// counts must be on the screen that deletes them.
        case cloudRefreshBookkeepingOnly
        /// settings-03. The page the disabled iCloud reset points to, behind the
        /// same row Settings shows. Its export is a recorder here.
        case cloudResetGuidance
        /// transfer-02. Local-only mode, where 「iCloudのデータを使う」 deletes
        /// the device's jar: an iCloud side holding none of the user's records,
        /// and an iCloud side that could not be read.
        case localEmptyCloud, localPreviewUnreadable
        /// transfer-07. Screen Time gems are in use, so every published
        /// switch discloses what it resets.
        case localScreenTime, cloudScreenTime
        /// The launch-host screens a fenced device actually lands on. Each one
        /// renders the shipping `PersistenceLaunchStatusView` with a recorder in
        /// place of the runtime, so no journal, container or CloudKit call
        /// exists in the process.
        case datasetRefreshChoice, datasetRefreshOtherDevices, datasetRefreshPreviewFailed
        case datasetRefreshBlocked, overwriteInProgress
        /// transfer-03. The shipping `.datasetRefresh` whose iCloud side holds
        /// none of the user's records.
        case datasetRefreshEmptyCloud
        /// transfer-04 / transfer-06: the generic blocked screen, a planned
        /// refresh continuation and the final relaunch.
        case launchBlockedGeneric, refreshInProgress, relaunchFinal
        /// `.remoteRecovery`, whose 「復旧を続ける」 door is gated by the resume
        /// bit — not by the legacy `allowsCloudReplacement`.
        case remoteResumeClosed, remoteResumeOpen
        /// P0-2. The screen the reported iPhone actually needs: the server has
        /// no transfer ledger, so the two honest choices are starting a lineage
        /// from this device or staying offline. `lineageUnavailable` is the
        /// shipping build (the first door disabled with its reason);
        /// `lineageUnavailableEnabled` raises only
        /// `allowsDatasetOverwriteFromDevice` so the consent flow is reachable.
        case lineageUnavailable, lineageUnavailableEnabled
        /// review-1-3 / review-2-1 and review-1-1 / review-2-2: the shipping
        /// build with an ineligible offline route (the screen must still carry
        /// a working control), and the published door whose read-only server
        /// enumeration failed (the door must stay shut).
        case lineageUnavailableClosed, lineageUnavailableUnreadable
        /// device-01. The shipping lineage screen for an account whose iCloud
        /// side holds none of the user's records.
        case lineageUnavailableEmptyCloud
        /// The two explanation-only screens. Neither carries any destructive
        /// control, in any policy.
        case environmentMismatch, localLedgerMissingExplain
        /// PLAN Step 9 / §6.5. The non-blocking banner a committed device ->
        /// iCloud replacement raises when the one post-commit comparison finds
        /// user records the committed payload did not hold.
        case lateArrival

        var overwriteLaunch: StorageTransferOverwriteLaunchUITestScenario? {
            switch self {
            case .datasetRefreshChoice: .choice
            case .datasetRefreshEmptyCloud: .refreshEmptyCloud
            case .datasetRefreshOtherDevices: .otherDevices
            case .datasetRefreshPreviewFailed: .previewFailed
            case .datasetRefreshBlocked: .blocked
            case .overwriteInProgress: .inProgress
            case .launchBlockedGeneric: .blockedGeneric
            case .refreshInProgress: .refreshInProgress
            case .relaunchFinal: .relaunchFinal
            case .remoteResumeClosed: .remoteResumeClosed
            case .remoteResumeOpen: .remoteResumeOpen
            case .lineageUnavailable: .lineageUnavailable
            case .lineageUnavailableEnabled: .lineageUnavailableEnabled
            case .lineageUnavailableClosed: .lineageUnavailableClosed
            case .lineageUnavailableUnreadable: .lineageUnavailableUnreadable
            case .lineageUnavailableEmptyCloud: .lineageUnavailableEmptyCloud
            case .environmentMismatch: .environmentMismatch
            case .localLedgerMissingExplain: .localLedgerMissingExplain
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
                || self == .cloudDatasetDoorsUnreadable || self == .cloudDatasetDoorsNoLineage
                || self == .cloudDatasetDoorsEmptyCloud || self == .cloudRefreshBookkeepingOnly
                || self == .cloudScreenTime
                || self == .lateArrival || isOffline
                || self == .cloudNetworkWaiting ? .cloudKit : .localOnly
        }

        /// Exactly one bit, and only for the one scenario that exercises a
        /// published door. The legacy `localOnly -> cloud` replacement and the
        /// remote resume stay closed, so a fixture can never widen the shipping
        /// prohibition it is meant to exercise around.
        var releasePolicy: StorageTransferReleasePolicy {
            self == .cloudDatasetDoors || self == .cloudDatasetDoorsUnreadable
                || self == .cloudDatasetDoorsNoLineage || self == .cloudDatasetDoorsEmptyCloud
                ? .isolatedTestingPolicy(allowsDatasetOverwriteFromDevice: true)
                : .standard
        }
        var disclosesScreenTimeReset: Bool { self == .localScreenTime || self == .cloudScreenTime }
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
    @State private var guidanceExportCalls = 0

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
        } else if scenario == .cloudLaunchTimedOutWithFocus {
            CloudLaunchTimeoutUITestFixtureView(wall: .timedOut, showsRunningFocus: true)
        } else if scenario == .cloudOfflineWallWithFocus {
            CloudLaunchTimeoutUITestFixtureView(wall: .offline, showsRunningFocus: true)
        } else if scenario == .cloudBackgroundReturnWithFocus {
            CloudLaunchTimeoutUITestFixtureView(wall: .backgroundReturn, showsRunningFocus: true)
        } else if scenario == .cloudResetGuidance {
            NavigationStack {
                List {
                    Section {
                        Text(verbatim: "calls=0;choice=none;starting=false")
                            .accessibilityIdentifier("storage-switch.fixture-state")
                        Text(verbatim: "guidanceExports=\(guidanceExportCalls)")
                            .accessibilityIdentifier("settings.reset-guidance.fixture-state")
                    }
                    Section("データ") {
                        Button("表示中の記録をリセット", role: .destructive) {}
                            .disabled(true)
                        Text(ActivityResetAdmissionPolicy.cloudResetUnavailableMessage)
                            .font(.caption)
                        NavigationLink {
                            CloudDataDeletionGuidanceView(isExporting: false) { guidanceExportCalls += 1 }
                        } label: {
                            Text(CloudDataDeletionGuidanceCopy.rowTitle)
                        }
                        .accessibilityIdentifier("settings.activity-reset-alternatives")
                    }
                }
                .navigationTitle("設定")
            }
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
                        releasePolicy: scenario.releasePolicy,
                        disclosesScreenTimeReset: scenario.disclosesScreenTimeReset
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
                guard scenario != .cloudDatasetDoorsUnreadable, scenario != .localPreviewUnreadable else {
                    throw CloudStorageTransferCloudError.timedOut
                }
                // transfer-03. The host reads this iPhone for every build now,
                // because 「iCloudから再取得」 ships and deletes this side.
                switch scenario {
                case .cloudDatasetDoorsNoLineage:
                    return Self.previewSummaryWithoutLineage(readsDeviceSide: true)
                case .cloudDatasetDoorsEmptyCloud:
                    return Self.previewSummaryEmptyCloud(readsDeviceSide: true)
                case .cloudRefreshBookkeepingOnly, .localEmptyCloud:
                    return Self.previewSummaryBookkeepingOnly()
                default:
                    return Self.previewSummary(readsDeviceSide: true)
                }
            })
        }
    }

    /// Two sides whose counts and dates differ, and one witnessed other
    /// device, so the sheet's comparison and evidence are both non-trivial.
    private static func previewSummary(readsDeviceSide: Bool) -> StorageTransferDatasetPreviewSummary {
        StorageTransferDatasetPreviewSummary(
            cloud: preview(subjects: 9, sessions: 312, stones: 28,
                           year: 2026, month: 9, day: 18, otherDeviceIDs: 2),
            device: deviceSide(readsDeviceSide))
    }

    /// W6. Records on the server, no transfer control record.
    private static func previewSummaryWithoutLineage(
        readsDeviceSide: Bool
    ) -> StorageTransferDatasetPreviewSummary {
        StorageTransferDatasetPreviewSummary(
            cloud: preview(subjects: 9, sessions: 312, stones: 28,
                           year: 2026, month: 9, day: 18, otherDeviceIDs: 0),
            device: deviceSide(readsDeviceSide),
            hasCloudLineage: false)
    }

    private static func deviceSide(_ reads: Bool) -> StorageTransferCloudPreview? {
        reads ? preview(subjects: 12, sessions: 480, stones: 36,
                        year: 2026, month: 9, day: 20, otherDeviceIDs: 0) : nil
    }

    /// review-1-2 / review-2-4. Nothing on the server, months of records on
    /// the device: the shape in which 「iCloudのデータは残ります」 is true and
    /// still leaves the user with an empty app and no copy anywhere.
    private static func previewSummaryEmptyCloud(
        readsDeviceSide: Bool
    ) -> StorageTransferDatasetPreviewSummary {
        StorageTransferDatasetPreviewSummary(
            cloud: preview(subjects: 0, sessions: 0, stones: 0,
                           year: 2026, month: 9, day: 18, otherDeviceIDs: 0),
            device: deviceSide(readsDeviceSide),
            hasCloudLineage: false)
    }

    /// transfer-03. Bookkeeping only: the rows every onboarded device mirrors.
    private static func previewSummaryBookkeepingOnly() -> StorageTransferDatasetPreviewSummary {
        let seeded = preview(subjects: 5, sessions: 0, stones: 0,
                             year: 2026, month: 9, day: 23, otherDeviceIDs: 1)
        var counts = seeded.recordCounts
        counts["Prefs"] = 1
        counts["FocusTimerDeviceClaim"] = 1
        return StorageTransferDatasetPreviewSummary(
            cloud: StorageTransferCloudPreview(recordCounts: counts,
                latestRecordAt: seeded.latestRecordAt, otherDeviceIDs: 1, ignoredWriterIDs: 0),
            device: deviceSide(true),
            hasCloudLineage: false)
    }

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
