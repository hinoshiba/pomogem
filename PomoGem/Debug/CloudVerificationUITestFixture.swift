#if DEBUG
import Foundation
import SwiftData

/// sync-03. Lets a Debug UI test see Home and the post-focus card while iCloud
/// verification is pending, which an in-memory preview never is: it has no
/// CloudKit and starts verified. Only the presentation context changes — no
/// store, account, checkpoint or CloudKit call is involved — and only in an
/// explicitly opted-in in-memory UI-test process. The whole type, including
/// its environment key, is absent from Release builds.
enum CloudVerificationUITestFixture {
    static let environmentKey = "POMOGEM_UI_TEST_CLOUD_VERIFICATION"
    /// A number of earlier 25-minute focus records to seed into the in-memory
    /// store before Home loads, so a pending jar can hold more history than
    /// Home materialises (review of PR #40).
    static let historyEnvironmentKey = "POMOGEM_UI_TEST_CLOUD_VERIFICATION_HISTORY"
    static let maximumSeededSessions = 1_000

    enum Mode: Equatable {
        /// Stays pending for the whole process.
        case pending
        /// Pending, then verified after this many seconds.
        case verifiedAfter(TimeInterval)
        /// Pending, verified after this many seconds, then pending again
        /// (as after the app's own save or a return from the background)
        /// the same number of seconds later.
        case verifiedThenPendingAfter(TimeInterval)
    }

    static func mode(environment: [String: String] = ProcessInfo.processInfo.environment) -> Mode? {
        guard LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess,
              LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess == .inMemoryPreview,
              let value = environment[environmentKey] else { return nil }
        if value == "pending" { return .pending }
        for (prefix, make) in [("verify-after-", Mode.verifiedAfter),
                               ("cycle-", Mode.verifiedThenPendingAfter)] {
            if value.hasPrefix(prefix),
               let seconds = TimeInterval(value.dropFirst(prefix.count)),
               seconds.isFinite, seconds > 0, seconds <= 600 {
                return make(seconds)
            }
        }
        return nil
    }

    static func seededSessionCount(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int? {
        guard mode(environment: environment) != nil,
              let value = environment[historyEnvironmentKey], let count = Int(value),
              (1...maximumSeededSessions).contains(count) else { return nil }
        return count
    }

    /// Inserts the requested history once, hourly, ending an hour ago, under
    /// the first theme. In-memory preview stores only.
    @MainActor
    static func seedHistoryIfRequested(context: ModelContext, now: Date = .now) {
        guard let count = seededSessionCount(),
              (try? context.fetchCount(FetchDescriptor<StudySession>())) == 0 else { return }
        let subject = try? context.fetch(FetchDescriptor<Subject>(sortBy: [SortDescriptor(\.sortOrder)])).first
        for index in 0..<count {
            let endAt = now.addingTimeInterval(-3_600 * Double(index + 1))
            context.insert(StudySession(
                subject: subject,
                startAt: endAt.addingTimeInterval(-1_500),
                endAt: endAt,
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "cloud-verification-fixture-\(index / 24)"
            ))
        }
        try? context.save()
    }

    /// The pending cloud context the fixture starts from.
    static var initialPresentation: AggregateProjectionPresentationContext? {
        guard mode() != nil else { return nil }
        return AggregateProjectionPresentationContext(usesCloudPersistence: true, isVerified: false,
                                                      cacheNamespace: UUID())
    }

    static var verificationDelay: TimeInterval? {
        switch mode() {
        case let .verifiedAfter(seconds), let .verifiedThenPendingAfter(seconds): seconds
        default: nil
        }
    }

    /// How long after verification the context becomes pending again.
    static var pendingAgainDelay: TimeInterval? {
        guard case let .verifiedThenPendingAfter(seconds) = mode() else { return nil }
        return seconds
    }
}
#endif
