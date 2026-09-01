#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Narrow, process-local failures for deterministic UI recovery tests.
///
/// Every gate also requires explicit UI-test mode and a validated, CloudKit-free
/// named fixture store. The entire implementation is compiled out of Release
/// and device builds, so injected environment values cannot affect user data.
@MainActor
enum UITestFaultInjection {
    static let focusCompletionSaveOnceEnvironmentKey =
        "TSUMIBEN_UI_TEST_FAULT_FOCUS_COMPLETION_SAVE_ONCE"
    static let aggregatePersistenceSaveOnceEnvironmentKey =
        "TSUMIBEN_UI_TEST_FAULT_AGGREGATE_SAVE_ONCE"

    private static var didConsumeFocusCompletionSaveFailure = false
    private static var didConsumeAggregatePersistenceSaveFailure = false

    static func consumeFocusCompletionSaveFailure(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard !didConsumeFocusCompletionSaveFailure,
              environment[focusCompletionSaveOnceEnvironmentKey] == "1",
              LocalPreviewLaunchPolicy.isUITestMode(
                  environment: environment,
                  isDebugBuild: true
              ),
              let request = FortyYearPersistentUITestFixture.request(
                  environment: environment
              ),
              request.action == .normal
        else { return false }

        // Consume before throwing so an explicit retry in this process reaches
        // the real save boundary exactly once.
        didConsumeFocusCompletionSaveFailure = true
        return true
    }

    static func isAggregatePersistenceSaveFailureEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard environment[aggregatePersistenceSaveOnceEnvironmentKey] == "1",
              LocalPreviewLaunchPolicy.isUITestMode(
                  environment: environment,
                  isDebugBuild: true
              ),
              let request = FortyYearPersistentUITestFixture.request(
                  environment: environment
              ),
              request.action == .normal
        else { return false }
        return true
    }

    static func consumeAggregatePersistenceSaveFailure(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard !didConsumeAggregatePersistenceSaveFailure,
              isAggregatePersistenceSaveFailureEnabled(environment: environment)
        else { return false }

        // Consume before throwing so the user's explicit retry reaches the
        // genuine ModelContext save boundary in the same process.
        didConsumeAggregatePersistenceSaveFailure = true
        return true
    }
}

enum UITestInjectedPersistenceError: LocalizedError {
    case focusCompletionSaveOnce
    case aggregatePersistenceSaveOnce

    var errorDescription: String? {
        switch self {
        case .focusCompletionSaveOnce:
            "UIテスト用に完走の保存を1回だけ失敗させました。"
        case .aggregatePersistenceSaveOnce:
            "UIテスト用にまとまり粒の保存を1回だけ失敗させました。"
        }
    }
}
#endif
