#if DEBUG
import Foundation

/// sync-03. Lets a Debug UI test see Home and the post-focus card while iCloud
/// verification is pending, which an in-memory preview never is: it has no
/// CloudKit and starts verified. Only the presentation context changes — no
/// store, account, checkpoint or CloudKit call is involved — and only in an
/// explicitly opted-in in-memory UI-test process. The whole type, including
/// its environment key, is absent from Release builds.
enum CloudVerificationUITestFixture {
    static let environmentKey = "POMOGEM_UI_TEST_CLOUD_VERIFICATION"

    enum Mode: Equatable {
        /// Stays pending for the whole process.
        case pending
        /// Pending, then verified after this many seconds.
        case verifiedAfter(TimeInterval)
    }

    static func mode(environment: [String: String] = ProcessInfo.processInfo.environment) -> Mode? {
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
              LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess == .inMemoryPreview,
              let value = environment[environmentKey] else { return nil }
        if value == "pending" { return .pending }
        if value.hasPrefix("verify-after-"),
           let seconds = TimeInterval(value.dropFirst("verify-after-".count)),
           seconds.isFinite, seconds > 0, seconds <= 600 {
            return .verifiedAfter(seconds)
        }
        return nil
    }

    /// The pending cloud context the fixture starts from.
    static var initialPresentation: AggregateProjectionPresentationContext? {
        guard mode() != nil else { return nil }
        return AggregateProjectionPresentationContext(usesCloudPersistence: true, isVerified: false,
                                                      cacheNamespace: UUID())
    }

    static var verificationDelay: TimeInterval? {
        guard case let .verifiedAfter(seconds) = mode() else { return nil }
        return seconds
    }
}
#endif
