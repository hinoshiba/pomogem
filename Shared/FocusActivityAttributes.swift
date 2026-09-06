import Foundation

#if !targetEnvironment(macCatalyst)
import ActivityKit

enum FocusActivityConstants {
    static let widgetKind = "PomoGemFocusLiveActivity"
    static let secondsPerMinute = 60
    static let dismissalDelay: TimeInterval = 2 * 60
}

/// The single source of truth shared by the app and Live Activity extension.
///
/// Keep attributes account-neutral because the system may retain a rendered
/// Live Activity after the app process exits. Only an opaque session ID and
/// numerical duration cross the extension boundary; category names, account
/// identifiers, notes, and CloudKit state never do.
struct FocusActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case running
            case paused
            case completed
        }

        let phase: Phase
        let endDate: Date?
        let pausedRemainingSeconds: Int?

        private init(
            phase: Phase,
            endDate: Date?,
            pausedRemainingSeconds: Int?
        ) {
            self.phase = phase
            self.endDate = endDate
            self.pausedRemainingSeconds = pausedRemainingSeconds
        }

        static func running(until endDate: Date) -> Self {
            Self(
                phase: .running,
                endDate: endDate,
                pausedRemainingSeconds: nil
            )
        }

        static func paused(remainingSeconds: Int) -> Self {
            Self(
                phase: .paused,
                endDate: nil,
                pausedRemainingSeconds: max(0, remainingSeconds)
            )
        }

        static func completed() -> Self {
            Self(
                phase: .completed,
                endDate: nil,
                pausedRemainingSeconds: nil
            )
        }
    }

    let sessionID: UUID
    let durationSeconds: Int

    init(
        sessionID: UUID,
        durationSeconds: Int
    ) {
        self.sessionID = sessionID
        self.durationSeconds = max(0, durationSeconds)
    }
}
#endif
