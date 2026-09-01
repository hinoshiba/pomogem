import ActivityKit
import SwiftUI
import WidgetKit

struct FocusLiveActivityWidget: Widget {
    let kind = IntegrationConstants.liveActivityWidgetKind

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FocusActivityAttributes.self) { context in
            FocusLockScreenView(context: context)
                .activityBackgroundTint(LivePalette.night)
                .activitySystemActionForegroundColor(LivePalette.warmText)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 7) {
                        SubjectMark(color: context.subjectColor)
                        Text(context.attributes.subjectName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(LivePalette.warmText)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    FocusStateText(
                        state: context.state,
                        fontSize: 18,
                        alignment: .trailing
                    )
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text("つみべん")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(LivePalette.amber)
                        Spacer()
                        if context.state.phase != .completed {
                            Text("\(context.attributes.durationSeconds / 60)分")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(LivePalette.mutedText)
                        }
                    }
                }
            } compactLeading: {
                SubjectMark(color: context.subjectColor)
            } compactTrailing: {
                FocusStateText(
                    state: context.state,
                    fontSize: 13,
                    alignment: .trailing
                )
                .frame(maxWidth: 54)
            } minimal: {
                SubjectMark(color: context.subjectColor)
            }
            .keylineTint(context.subjectColor)
        }
    }
}

private struct FocusLockScreenView: View {
    let context: ActivityViewContext<FocusActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(context.subjectColor.opacity(0.18))
                    .frame(width: 42, height: 42)
                SubjectMark(color: context.subjectColor, size: 18)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("つみべん")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(LivePalette.amber)
                Text(context.attributes.subjectName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LivePalette.warmText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            FocusStateText(
                state: context.state,
                fontSize: context.state.phase == .completed ? 16 : 25,
                alignment: .trailing
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }
}

private struct SubjectMark: View {
    let color: Color
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.34), lineWidth: 1)
            }
            .shadow(color: color.opacity(0.7), radius: 4)
    }
}

private struct FocusStateText: View {
    let state: FocusActivityAttributes.ContentState
    let fontSize: CGFloat
    let alignment: Alignment

    var body: some View {
        Group {
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
                } else {
                    Text("00:00")
                }
            case .paused:
                Text(Self.clockText(seconds: state.pausedRemainingSeconds ?? 0))
            case .completed:
                Text("+\(state.completedGrams ?? IntegrationConstants.defaultCompletedGrams)g 積まれた")
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

private extension ActivityViewContext where Attributes == FocusActivityAttributes {
    var subjectColor: Color {
        Color(tsumibenHex: attributes.subjectColorHex) ?? LivePalette.amber
    }
}

private extension Color {
    init?(tsumibenHex: String) {
        let value = tsumibenHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else {
            return nil
        }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

private enum LivePalette {
    static let night = Color(red: 20 / 255, green: 25 / 255, blue: 39 / 255)
    static let amber = Color(red: 232 / 255, green: 180 / 255, blue: 74 / 255)
    static let warmText = Color(red: 242 / 255, green: 239 / 255, blue: 231 / 255)
    static let mutedText = Color(red: 139 / 255, green: 147 / 255, blue: 172 / 255)
}
