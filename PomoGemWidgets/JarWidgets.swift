import Foundation
import SwiftUI
import WidgetKit

private struct JarWidgetEntry: TimelineEntry {
    let date: Date
}

private struct JarTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> JarWidgetEntry {
        JarWidgetEntry(date: .now)
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (JarWidgetEntry) -> Void
    ) {
        completion(JarWidgetEntry(date: .now))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<JarWidgetEntry>) -> Void
    ) {
        completion(Timeline(
            entries: [JarWidgetEntry(date: .now)],
            policy: .never
        ))
    }
}

private enum NeutralWidgetConstants {
    static let homeKind = "PomoGemJarWidget"
    static let lockScreenKind = "PomoGemMassWidget"
}

struct JarHomeWidget: Widget {
    let kind = NeutralWidgetConstants.homeKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JarTimelineProvider()) { entry in
            JarHomeWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetPalette.backgroundGradient
                }
        }
        .configurationDisplayName("ポモジェム")
        .description("今日の集中を始める")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

/// Every tap starts a focus in the app exactly as Home's start button does,
/// with the theme and length chosen there (notify-03, product-04). The URLs
/// are constants: the widget still reads and shows no user data.
private struct JarHomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: JarWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                mediumLayout
            default:
                smallLayout
            }
        }
        .widgetURL(AppEntryLink.focusStartURL())
    }

    private var smallLayout: some View {
        VStack(spacing: 8) {
            wordmark
            NeutralJarArtwork()
                .frame(maxHeight: .infinity)
            Text("集中を始める")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(WidgetPalette.warmText)
                .lineLimit(1)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("ポモジェムで集中を始める")
    }

    /// The jar and the heading on top, then one row of equal buttons across
    /// the whole width, so all four free lengths fit even the narrowest
    /// medium widget with a comfortable tap target each.
    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                NeutralJarArtwork()
                    .frame(width: 88)

                VStack(alignment: .leading, spacing: 4) {
                    wordmark
                    Text("今日のひと粒を積もう")
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .foregroundStyle(WidgetPalette.warmText)
                        .minimumScaleFactor(0.72)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("ポモジェムで今日の集中を始める")
            }
            .frame(maxHeight: .infinity)

            FocusPresetLinks()
        }
        .padding(14)
        // The heading and each length stay separate for VoiceOver.
        .accessibilityElement(children: .contain)
    }

    private var wordmark: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(WidgetPalette.amber)
                .frame(width: 7, height: 7)
                .shadow(color: WidgetPalette.amber.opacity(0.7), radius: 4)
            Text("ポモジェム")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetPalette.amber)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

}

/// One tap to a focus of a free length. The widget cannot know the length
/// last used in the app, so the rest of the widget starts with that one and
/// these offer the fixed lengths the Home picker offers everyone.
private struct FocusPresetLinks: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(FocusStartPreset.allCases, id: \.self) { preset in
                Link(destination: AppEntryLink.focusStartURL(preset)) {
                    // Timer lengths, as Home's picker writes them: 「90分」.
                    Text(verbatim: DurationText.short(seconds: preset.seconds, units: .minutesSeconds))
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(WidgetPalette.night)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(WidgetPalette.amber, in: Capsule())
                }
                .accessibilityLabel(String(
                    localized: "\(DurationText.spoken(seconds: preset.seconds, units: .minutesSeconds))集中する",
                    table: "Widgets",
                    comment: "VoiceOver: a medium-widget button that starts a focus; the argument is its length, e.g. 25分"
                ))
            }
        }
    }
}

private struct NeutralJarArtwork: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(WidgetPalette.card.opacity(0.62))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(WidgetPalette.glassEdge, lineWidth: 1)

            VStack(spacing: 7) {
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 29, weight: .light))
                    .foregroundStyle(WidgetPalette.amber)
                Text("ひと粒ずつ")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.mutedText)
            }
        }
        .accessibilityHidden(true)
    }
}

struct JarLockScreenWidget: Widget {
    let kind = NeutralWidgetConstants.lockScreenKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JarTimelineProvider()) { entry in
            JarLockScreenView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("ポモジェム")
        .description("集中を始める")
        .supportedFamilies([
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

private struct JarLockScreenView: View {
    @Environment(\.widgetFamily) private var family
    let entry: JarWidgetEntry

    var body: some View {
        content
            .widgetURL(AppEntryLink.focusStartURL())
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            Label(
                "集中を始める",
                systemImage: "circle.grid.3x3.fill"
            )
        case .accessoryCircular:
            VStack(spacing: -2) {
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("集中")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                Label("ポモジェム", systemImage: "circle.grid.3x3.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("集中を始める")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private enum WidgetPalette {
    static let night = Color(red: 20 / 255, green: 25 / 255, blue: 39 / 255)
    static let card = Color(red: 27 / 255, green: 33 / 255, blue: 54 / 255)
    static let amber = Color(red: 232 / 255, green: 180 / 255, blue: 74 / 255)
    static let warmText = Color(red: 242 / 255, green: 239 / 255, blue: 231 / 255)
    static let mutedText = Color(red: 139 / 255, green: 147 / 255, blue: 172 / 255)
    static let glassEdge = Color(
        red: 170 / 255,
        green: 195 / 255,
        blue: 240 / 255,
        opacity: 0.35
    )

    static let backgroundGradient = LinearGradient(
        colors: [night, card.opacity(0.94)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
