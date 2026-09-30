import Foundation

#if !targetEnvironment(macCatalyst)
import ActivityKit

enum FocusActivityConstants {
    static let widgetKind = "PomoGemFocusLiveActivity"
    static let secondsPerMinute = 60
    static let dismissalDelay: TimeInterval = 2 * 60

    /// The timer's length as the app labels it (「25分」「1分30秒」; en
    /// "25 min", "1 min 30 sec"). Formatted by `DurationText`, which the widget
    /// extension compiles too, so this file needs no String Catalog key: the
    /// widget bundle has no table for Shared code. An empty length reads
    /// 「0分」 as it always has, not DurationText's 「0秒」.
    static func durationLabel(seconds: Int, locale: Locale = PomoGemLocale.current) -> String {
        let value = max(0, seconds)
        guard value > 0 else { return DurationText.short(minutes: 0, locale: locale) }
        return DurationText.short(seconds: value, units: .minutesSeconds, locale: locale)
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
