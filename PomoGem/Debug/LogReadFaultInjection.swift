#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Slow or failing reads of 記録's history, for UI tests of what 記録 shows
/// while it reads and after a read fails. On the preview store the reads
/// finish before XCUI can look, so neither state could be seen otherwise.
///
/// Every gate also requires explicit UI-test mode and the in-memory preview
/// store. The whole implementation is compiled out of Release and device
/// builds, so an injected environment value cannot slow or fail a real read.
enum LogReadFaultInjection {
    static let environmentKey = "POMOGEM_UI_TEST_LOG_READS"

    enum Mode: String {
        /// Every read of 記録's history waits `slowReadDelay` before it
        /// starts, holding its turn in LogReadQueue as a slow read would.
        case slow
        /// The read of the newest records and aggregates fails.
        case failRecent = "fail-recent"
    }

    /// Long enough for XCUI to look on a busy build machine, where one
    /// query can take seconds.
    static let slowReadDelay: Duration = .seconds(8)

    static func mode(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Mode? {
        guard LocalPreviewLaunchPolicy.isEnabled(environment: environment, isDebugBuild: true),
              LocalPreviewLaunchPolicy.isUITestMode(environment: environment, isDebugBuild: true)
        else { return nil }
        return environment[environmentKey].flatMap(Mode.init(rawValue:))
    }

    /// Runs at the start of a read's turn in LogReadQueue.
    static func beforeRead(_ part: LogHistoryLoadPolicy.Part) async throws {
        switch mode() {
        case .slow?:
            try await Task.sleep(for: slowReadDelay)
        case .failRecent? where part == .recent:
            throw LogReadInjectedError.recentReadFailed
        default:
            return
        }
    }
}

enum LogReadInjectedError: Error {
    case recentReadFailed
}
#endif
