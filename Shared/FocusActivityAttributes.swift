import Foundation

#if !targetEnvironment(macCatalyst)
import ActivityKit

/// The single source of truth shared by the app and Live Activity extension.
struct FocusActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        enum Phase: String, Codable, Hashable, Sendable {
            case running
            case paused
            case completed
        }

        var phase: Phase
        var endDate: Date?
        var pausedRemainingSeconds: Int?
        var completedGrams: Int?

        static func running(until endDate: Date) -> Self {
            Self(
                phase: .running,
                endDate: endDate,
                pausedRemainingSeconds: nil,
                completedGrams: nil
            )
        }

        static func paused(remainingSeconds: Int) -> Self {
            Self(
                phase: .paused,
                endDate: nil,
                pausedRemainingSeconds: max(0, remainingSeconds),
                completedGrams: nil
            )
        }

        static func completed(
            grams: Int = IntegrationConstants.defaultCompletedGrams
        ) -> Self {
            Self(
                phase: .completed,
                endDate: nil,
                pausedRemainingSeconds: nil,
                completedGrams: max(0, grams)
            )
        }
    }

    let sessionID: UUID
    let subjectName: String
    let subjectColorHex: String
    let durationSeconds: Int
}
#endif
