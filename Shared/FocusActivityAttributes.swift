import Foundation

#if !targetEnvironment(macCatalyst)
import ActivityKit

enum FocusActivityConstants {
    static let widgetKind = "PomoGemFocusLiveActivity"
    static let secondsPerMinute = 60
    static let dismissalDelay: TimeInterval = 2 * 60

    static func durationLabel(seconds: Int) -> String {
        let value = max(0, seconds)
        let minutes = value / secondsPerMinute
        let remainder = value % secondsPerMinute
        if remainder == 0 { return "\(minutes)分" }
        if minutes == 0 { return "\(remainder)秒" }
        return "\(minutes)分\(remainder)秒"
    }
}

/// The single source of truth shared by the app and Live Activity extension.
///
/// Keep attributes account-neutral because the system may retain a rendered
/// Live Activity after the app process exits. Only an opaque session ID and
/// numerical duration cross the extension boundary; category names, account
/// identifiers, notes, and CloudKit state never do.
///
/// A break the person chose after a focus uses the same attributes: its
/// session ID is the break's own random UUID and its duration is the break
/// length, so the rest adds no new kind of data to the surface.
struct FocusActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        /// ActivityKit state only. It is never persisted or synced, and the app
        /// and the extension ship together, so a new case cannot reach an
        /// older reader.
        enum Phase: String, Codable, Hashable, Sendable {
            case running
            case paused
            case completed
            /// The chosen break is counting down (notify-06).
            case breakRunning
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

        /// Breaks cannot be paused, so the end date is the whole state. The
        /// system renders the countdown and marks it stale at `endDate`.
        static func breakRunning(until endDate: Date) -> Self {
            Self(
                phase: .breakRunning,
                endDate: endDate,
                pausedRemainingSeconds: nil
            )
        }

        var isBreak: Bool { phase == .breakRunning }
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
