import ActivityKit
import SwiftUI
import WidgetKit

struct FocusLiveActivityWidget: Widget {
    let kind = FocusActivityConstants.widgetKind

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            FocusLockScreenView(context: context)
                .activityBackgroundTint(LivePalette.night)
                .activitySystemActionForegroundColor(LivePalette.warmText)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text("つみべん")
                    } icon: {
                        Image(systemName: "timer")
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(LivePalette.amber)
                    .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    FocusStateText(
                        state: context.state,
                        isStale: context.isStale,
                        fontSize: 18,
                        alignment: .trailing
                    )
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        HStack {
                            Text(focusStatusTitle(
                                state: context.state,
                                isStale: context.isStale
                            ))
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(LivePalette.mutedText)
                            Spacer()
                            if context.state.phase != .completed,
                               !context.isStale {
                                Text("\(context.attributes.durationSeconds / 60)分")
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(LivePalette.mutedText)
                            }
                        }

                        FocusTimeProgress(
                            state: context.state,
                            isStale: context.isStale,
                            durationSeconds: context.attributes.durationSeconds
                        )
                    }
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(LivePalette.amber)
            } compactTrailing: {
                FocusStateText(
                    state: context.state,
                    isStale: context.isStale,
                    fontSize: 13,
                    alignment: .trailing
                )
                .frame(maxWidth: 58)
            } minimal: {
                Image(systemName: "timer")
                    .foregroundStyle(LivePalette.amber)
            }
            .keylineTint(LivePalette.amber)
        }
    }
}

private struct FocusLockScreenView: View {
    let context: ActivityViewContext<FocusActivityAttributes>

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(LivePalette.amber.opacity(0.18))
                        .frame(width: 42, height: 42)
                    Image(systemName: "timer")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(LivePalette.amber)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("つみべん")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(LivePalette.amber)
                    Text(focusStatusTitle(
                        state: context.state,
                        isStale: context.isStale
                    ))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(LivePalette.warmText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                FocusStateText(
                    state: context.state,
                    isStale: context.isStale,
                    fontSize: context.state.phase == .completed ? 16 : 25,
                    alignment: .trailing
                )
            }

            FocusTimeProgress(
                state: context.state,
                isStale: context.isStale,
                durationSeconds: context.attributes.durationSeconds
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }
}

/// A date-relative progress view is rendered and advanced by the system, so it
/// keeps depleting while the host app and widget extension are suspended.
/// SwiftUI doesn't support custom styles for date-relative progress, therefore
/// this deliberately uses the reliable system bar instead of a faux animated
/// circular shape that would freeze in the background.
private struct FocusTimeProgress: View {
    let state: FocusActivityAttributes.ContentState
    let isStale: Bool
    let durationSeconds: Int

    var body: some View {
        Group {
            if isStale || state.phase == .completed {
                ProgressView(value: 0, total: 1)
            } else {
                switch state.phase {
                case .running:
                    if let endDate = state.endDate {
                        ProgressView(
                            timerInterval: startDate(for: endDate)...endDate,
                            countsDown: true
                        )
                    } else {
                        ProgressView(value: 0, total: 1)
                    }
                case .paused:
                    ProgressView(
                        value: Double(clampedPausedSeconds),
                        total: Double(safeDurationSeconds)
                    )
                case .completed:
                    ProgressView(value: 0, total: 1)
                }
            }
        }
        .tint(LivePalette.amber)
        .labelsHidden()
        .accessibilityHidden(true)
    }

    private var safeDurationSeconds: Int {
        max(1, durationSeconds)
    }

    private var clampedPausedSeconds: Int {
        min(
            safeDurationSeconds,
            max(0, state.pausedRemainingSeconds ?? 0)
        )
    }

    private func startDate(for endDate: Date) -> Date {
        endDate.addingTimeInterval(-TimeInterval(safeDurationSeconds))
    }
}

private struct FocusStateText: View {
    let state: FocusActivityAttributes.ContentState
    let isStale: Bool
    let fontSize: CGFloat
    let alignment: Alignment

    var body: some View {
        Group {
            if isStale, state.phase == .running {
                Text("終了")
                    .accessibilityLabel("集中完了")
            } else {
                switch state.phase {
                case .running:
                    if let endDate = state.endDate {
                        let startDate = min(Date.now, endDate)
                        Text(
                            timerInterval: startDate...endDate,
                            pauseTime: nil,
                            countsDown: true,
                            showsHours: true
                        )
                        .accessibilityLabel(
                            Text("残り時間、")
                                + Text(
                                    timerInterval: startDate...endDate,
                                    pauseTime: nil,
                                    countsDown: true,
                                    showsHours: true
                                )
                        )
                    } else {
                        Text("00:00")
                            .accessibilityLabel("残り時間")
                            .accessibilityValue("00:00")
                    }
                case .paused:
                    Text(Self.clockText(seconds: state.pausedRemainingSeconds ?? 0))
                        .accessibilityLabel("一時停止中の残り時間")
                        .accessibilityValue(
                            Self.clockText(seconds: state.pausedRemainingSeconds ?? 0)
                        )
                case .completed:
                    Text("完了")
                        .accessibilityLabel("集中完了")
                }
            }
        }
        .font(.system(size: fontSize, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(
            state.phase == .completed ? LivePalette.amber : LivePalette.warmText
        )
        .minimumScaleFactor(0.6)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: alignment)
    }

    private static func clockText(seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}

private enum LivePalette {
    static let night = Color(red: 20 / 255, green: 25 / 255, blue: 39 / 255)
    static let amber = Color(red: 232 / 255, green: 180 / 255, blue: 74 / 255)
    static let warmText = Color(red: 242 / 255, green: 239 / 255, blue: 231 / 255)
    static let mutedText = Color(red: 139 / 255, green: 147 / 255, blue: 172 / 255)
}

private func focusStatusTitle(
    state: FocusActivityAttributes.ContentState,
    isStale: Bool
) -> String {
    if isStale || state.phase == .completed {
        return "集中完了"
    }
    if state.phase == .paused {
        return "一時停止中"
    }
    return "集中を続けています"
}
