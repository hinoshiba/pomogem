import SwiftData
import SwiftUI

enum PersistenceLaunchMode: Equatable {
    case inMemoryPreview
    case persistentSimulator
    case cloudKit
}

enum LocalPreviewLaunchPolicy {
#if DEBUG
    static let environmentKey = "TSUMIBEN_LOCAL_PREVIEW"
    static let uiTestEnvironmentKey = "TSUMIBEN_UI_TEST_MODE"
    static let persistentUITestStoreEnvironmentKey = "TSUMIBEN_UI_TEST_PERSISTENT_STORE"
    static let accessibility5EnvironmentKey = "TSUMIBEN_UI_TEST_AX5"
    static let unselectedRareRewardUITestEnvironmentKey = "TSUMIBEN_UI_TEST_RARE_REWARD_UNSELECTED"
    static let rareRewardOnboardingUITestEnvironmentKey = "TSUMIBEN_UI_TEST_RARE_REWARD_ONBOARDING"
#else
    // Keep the policy API available to ordinary production code while making
    // the test protocol and its environment tokens absent from Release output.
    static let environmentKey = ""
    static let uiTestEnvironmentKey = ""
    static let persistentUITestStoreEnvironmentKey = ""
    static let accessibility5EnvironmentKey = ""
    static let unselectedRareRewardUITestEnvironmentKey = ""
    static let rareRewardOnboardingUITestEnvironmentKey = ""
#endif

    static func isEnabled(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> Bool {
        isDebugBuild && environment[environmentKey] == "1"
    }

    /// UI-test affordances require a second explicit opt-in in addition to the
    /// local in-memory store. This keeps normal Debug previews useful without
    /// changing navigation or accessibility, and Release builds can never
    /// enable the test-only path from an injected process environment.
    static func isUITestMode(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> Bool {
        isDebugBuild
            && environment[uiTestEnvironmentKey] == "1"
            && (isEnabled(environment: environment, isDebugBuild: isDebugBuild)
                || environment[persistentUITestStoreEnvironmentKey] != nil)
    }

    /// Forces the largest Dynamic Type category only inside an explicitly
    /// opted-in Debug UI-test process. Production and ordinary Debug launches
    /// must always continue to follow the user's system text-size setting.
    static func forcesAccessibility5(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> Bool {
        isUITestMode(environment: environment, isDebugBuild: isDebugBuild)
            && environment[accessibility5EnvironmentKey] == "1"
    }

    /// An unsigned Debug simulator app cannot open CloudKit: Core Data starts
    /// that setup asynchronously and CloudKit traps before `ModelContainer`'s
    /// throwing initializer can report an error. Keep explicit previews
    /// in-memory, give ordinary Debug simulator launches their own persistent
    /// local store, and leave device/Release builds on the private iCloud store.
    static func persistenceMode(
        environment: [String: String],
        isDebugBuild: Bool,
        isSimulator: Bool
    ) -> PersistenceLaunchMode {
        if isEnabled(environment: environment, isDebugBuild: isDebugBuild) {
            return .inMemoryPreview
        }
        if isDebugBuild && isSimulator {
            return .persistentSimulator
        }
        return .cloudKit
    }

    static var isEnabledForCurrentProcess: Bool {
#if DEBUG
        isEnabled(environment: ProcessInfo.processInfo.environment, isDebugBuild: true)
#else
        false
#endif
    }

    static var isUITestModeForCurrentProcess: Bool {
#if DEBUG
        isUITestMode(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: true
        )
#else
        false
#endif
    }


    static var persistenceModeForCurrentProcess: PersistenceLaunchMode {
#if DEBUG && targetEnvironment(simulator)
        persistenceMode(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: true,
            isSimulator: true
        )
#elseif DEBUG
        persistenceMode(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: true,
            isSimulator: false
        )
#else
        .cloudKit
#endif
    }
}

@main
struct TsumibenApp: App {
    private let container: ModelContainer
    private let persistenceStartupError: String?
    private let persistentFixtureActionRawValue: String?

    init() {
        let schema = Schema([
            Subject.self,
            StudySession.self,
            AchievementStone.self,
            AggregatePebble.self,
            Stratum.self,
            Bedrock.self,
            GachaState.self,
            Prefs.self,
            ActivityResetMarker.self,
            SyncedFocusTimer.self,
            FocusTimerDeviceClaim.self
        ])

#if DEBUG && targetEnvironment(simulator)
        let persistentFixtureRequest = FortyYearPersistentUITestFixture.request(
            environment: ProcessInfo.processInfo.environment
        )
        persistentFixtureActionRawValue = persistentFixtureRequest?.action.rawValue
        if let persistentFixtureRequest {
            do {
                let configuration = try FortyYearPersistentUITestFixture.makeConfiguration(
                    schema: schema,
                    request: persistentFixtureRequest
                )
                container = try ModelContainer(
                    for: schema,
                    configurations: [configuration]
                )
                persistenceStartupError = nil
                return
            } catch {
                fatalError("UIテスト専用ストアを開けませんでした: \(error.localizedDescription)")
            }
        }
#else
        persistentFixtureActionRawValue = nil
#endif

        // Explicit UI/visual previews are disposable. A normally launched
        // Debug simulator instead gets a persistent local database so the app
        // remains tappable from SpringBoard and long-range QA survives relaunch.
        if LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess == .inMemoryPreview {
            let localPreview = ModelConfiguration(
                "TsumibenLocalPreview",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            do {
                container = try ModelContainer(
                    for: schema,
                    configurations: [localPreview]
                )
                persistenceStartupError = nil
                return
            } catch {
                fatalError("Simulatorプレビューを開けませんでした: \(error.localizedDescription)")
            }
        }

        if LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess == .persistentSimulator {
            let simulator = ModelConfiguration(
                "TsumibenSimulator",
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
            do {
                container = try ModelContainer(
                    for: schema,
                    configurations: [simulator]
                )
                persistenceStartupError = nil
                return
            } catch {
                persistenceStartupError = error.localizedDescription
                let emergency = ModelConfiguration(
                    "TsumibenSimulatorUnavailable",
                    schema: schema,
                    isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none
                )
                do {
                    container = try ModelContainer(
                        for: schema,
                        configurations: [emergency]
                    )
                } catch {
                    fatalError("Simulatorの保存領域を開けませんでした: \(error.localizedDescription)")
                }
                return
            }
        }

        do {
            let cloud = ModelConfiguration(
                "Tsumiben",
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .private(CloudSyncConfiguration.containerIdentifier)
            )
            container = try ModelContainer(for: schema, configurations: [cloud])
            persistenceStartupError = nil
        } catch {
            // The private CloudKit store remains usable offline.
            // If the store itself cannot open, never switch to a second
            // persistent database: doing so would make newly entered records
            // appear to vanish when the primary store becomes available.
            persistenceStartupError = error.localizedDescription
            let emergency = ModelConfiguration(
                "TsumibenUnavailable",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
            do {
                container = try ModelContainer(for: schema, configurations: [emergency])
            } catch {
                fatalError("つみべんの保存領域を開けませんでした: \(error.localizedDescription)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG && targetEnvironment(simulator)
            if FortyYearPersistentUITestFixture.showsOverviewForCurrentProcess {
                FortyYearOverviewFixtureLaunchView()
            } else if let rawValue = persistentFixtureActionRawValue,
               let action = FortyYearPersistentUITestFixture.Action(rawValue: rawValue),
               action != .normal {
                FortyYearPersistentFixtureLaunchView(
                    container: container,
                    action: action
                )
                .preferredColorScheme(.dark)
                .tint(TsumibenTheme.amber)
            } else {
                rootContent
            }
#else
            rootContent
#endif
        }
        .modelContainer(container)
    }

    @ViewBuilder
    private var rootContent: some View {
#if DEBUG && targetEnvironment(simulator)
        if LocalPreviewLaunchPolicy.forcesAccessibility5(
            environment: ProcessInfo.processInfo.environment,
            isDebugBuild: true
        ) {
            baseRootContent
                .environment(\.dynamicTypeSize, .accessibility5)
        } else {
            baseRootContent
        }
#else
        baseRootContent
#endif
    }

    private var baseRootContent: some View {
        RootView(persistenceStartupError: persistenceStartupError)
            .preferredColorScheme(.dark)
            .tint(TsumibenTheme.amber)
    }
}
