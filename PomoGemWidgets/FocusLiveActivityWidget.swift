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
                        Text("ポモジェム")
                    } icon: {
                        Image(systemName: phaseSymbol(state: context.state))
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
                            // The length the person chose: the focus or,
                            // during a rest, the break's 5 or 15 minutes.
                            if context.state.phase != .completed,
                               !context.isStale {
                                Text(FocusActivityConstants.durationLabel(
                                    seconds: context.attributes.durationSeconds
                                ))
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .foregroundStyle(LivePalette.mutedText)
                            }
                        }

                        FocusTimeProgress(
                            state: context.state,
                            isStale: context.isStale,
                            durationSeconds: context.attributes.durationSeconds
                        )

                        FocusReturnGuidance(
                            state: context.state,
                            isStale: context.isStale
                        )
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(focusReturnGuidance(
                        state: context.state,
                        isStale: context.isStale
                    ))
                }
            } compactLeading: {
                PhaseSymbol(state: context.state)
            } compactTrailing: {
                FocusStateText(
                    state: context.state,
                    isStale: context.isStale,
                    fontSize: 13,
                    alignment: .trailing
                )
                .frame(maxWidth: 58)
                .accessibilityHint(focusReturnGuidance(
                    state: context.state,
                    isStale: context.isStale
                ))
            } minimal: {
                PhaseSymbol(state: context.state)
                    .accessibilityHint(focusReturnGuidance(
                        state: context.state,
                        isStale: context.isStale
                    ))
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
                    Image(systemName: phaseSymbol(state: context.state))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(LivePalette.amber)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("ポモジェム")
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

            FocusReturnGuidance(
                state: context.state,
                isStale: context.isStale
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
        .accessibilityHint(focusReturnGuidance(
            state: context.state,
            isStale: context.isStale
        ))
    }
}

/// The compact and minimal Dynamic Island mark: a timer while focusing, a cup
/// while resting, the same symbols the app's own screens use.
private struct PhaseSymbol: View {
    let state: FocusActivityAttributes.ContentState

    var body: some View {
        Image(systemName: phaseSymbol(state: state))
            .foregroundStyle(LivePalette.amber)
            .accessibilityLabel(
                state.isBreak
                    ? String(
                        localized: "ポモジェムの休憩",
                        table: "Widgets",
                        comment: "VoiceOver: the Dynamic Island mark during a break"
                    )
                    : String(
                        localized: "ポモジェムのタイマー",
                        table: "Widgets",
                        comment: "VoiceOver: the Dynamic Island mark during a focus"
                    )
            )
    }
}

/// Tapping the Live Activity already opens its containing app. This is a
/// description of that system action, not a separate button or a timer command.
private struct FocusReturnGuidance: View {
    let state: FocusActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        Text(focusReturnGuidance(state: state, isStale: isStale))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(LivePalette.mutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            // The enclosing surface exposes the same instruction as its hint.
            .accessibilityHidden(true)
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
                case .running, .breakRunning:
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
            if isStale, state.phase == .breakRunning {
                Text("終了", tableName: "Widgets", comment: "Live Activity countdown after its end time")
                    .accessibilityLabel(
                        Text("休憩終了", tableName: "Widgets", comment: "Live Activity: a break past its end time (title and VoiceOver)")
                    )
            } else if isStale, state.phase == .running {
                Text("終了")
                    .accessibilityLabel("集中完了")
            } else {
                switch state.phase {
                case .running:
                    if let endDate = state.endDate {
                        let startDate = min(Date.now, endDate)
                        // Count in total minutes (「89:59」), like the app's
                        // timer, the paused state below and the 「90分」 label.
                        // Hours would make one timer read 1:29:59 here only.
                        Text(
                            timerInterval: startDate...endDate,
                            pauseTime: nil,
                            countsDown: true,
                            showsHours: false
                        )
                        .accessibilityLabel(
                            Text("残り時間、")
                                + Text(
                                    timerInterval: startDate...endDate,
                                    pauseTime: nil,
                                    countsDown: true,
                                    showsHours: false
                                )
                        )
                    } else {
                        Text("00:00")
                            .accessibilityLabel("残り時間")
                            .accessibilityValue("00:00")
                    }
                case .breakRunning:
                    if let endDate = state.endDate {
                        let startDate = min(Date.now, endDate)
                        let countdown = Text(
                            timerInterval: startDate...endDate,
                            pauseTime: nil,
                            countsDown: true,
                            showsHours: false
                        )
                        countdown
                            .accessibilityLabel(
                                Text(
                                    "休憩の残り時間、\(countdown)",
                                    tableName: "Widgets",
                                    comment: "VoiceOver: the break countdown; the argument is the remaining time"
                                )
                            )
                    } else {
                        Text("00:00")
                            .accessibilityLabel(
                                Text(
                                    "休憩の残り時間",
                                    tableName: "Widgets",
                                    comment: "VoiceOver: label of an unknown break countdown"
                                )
                            )
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

private func phaseSymbol(state: FocusActivityAttributes.ContentState) -> String {
    state.isBreak ? "cup.and.saucer.fill" : "timer"
}

private func focusStatusTitle(
    state: FocusActivityAttributes.ContentState,
    isStale: Bool
) -> String {
    if state.isBreak {
        // A break ended while the app was suspended stays on the Lock Screen
        // until the app runs again; say so plainly instead of 「集中完了」.
        return isStale
            ? String(localized: "休憩終了", table: "Widgets", comment: "Live Activity: a break past its end time (title and VoiceOver)")
            : String(localized: "休憩中", table: "Widgets", comment: "Live Activity title while a break counts down")
    }
    if isStale || state.phase == .completed {
        return "集中完了"
    }
    if state.phase == .paused {
        return "一時停止中"
    }
    return "集中を続けています"
}

private func focusReturnGuidance(
    state: FocusActivityAttributes.ContentState,
    isStale: Bool
) -> String {
    if state.isBreak {
        return isStale
            ? String(localized: "タップして瓶へ戻る", table: "Widgets", comment: "Live Activity guidance after a break ended; the app's break screen offers 「瓶へ戻る」")
            : String(localized: "タップして休憩へ戻る", table: "Widgets", comment: "Live Activity guidance while a break counts down; like 「タップして集中へ戻る」 for a focus")
    }
    if isStale || state.phase == .completed {
        return "タップして完了を確認"
    }
    if state.phase == .paused {
        return "タップしてタイマーへ"
    }
    return "タップして集中へ戻る"
}
