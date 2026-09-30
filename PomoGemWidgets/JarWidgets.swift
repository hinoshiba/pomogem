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
        .configurationDisplayName(Text("ポモジェム", tableName: "Widgets", comment: "The app's name, in the widget gallery, on the widgets and on the Live Activity"))
        .description(Text("今日の集中を始める", tableName: "Widgets", comment: "Widget gallery: what the Home Screen widget does"))
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

/// Taps start a focus in the app exactly as Home's start button does, with
/// the theme chosen there (notify-03, product-04). The small widget says
/// 「集中を始める」 and uses the length chosen in the app; the medium one
/// starts only from its four length buttons, whose length is on the button,
/// and the rest of it opens the jar. The URLs are constants: the widget still
/// reads and shows no user data.
private struct JarHomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: JarWidgetEntry

    var body: some View {
        switch family {
        case .systemMedium:
            // The jar and heading cannot show the length a start would use,
            // so they open the app; the buttons below are the starts.
            mediumLayout
                .widgetURL(AppEntryLink.homeURL)
        default:
            smallLayout
                .widgetURL(AppEntryLink.focusStartURL())
        }
    }

    private var smallLayout: some View {
        VStack(spacing: 6) {
            wordmark
            // The widget's own opaque navy is the plate here.
            NeutralJarArtwork(framed: false)
                .frame(maxHeight: .infinity)
            Text("集中を始める", tableName: "Widgets", comment: "Widget button text that starts a focus (the app's Start Focus)")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(WidgetPalette.warmText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("ポモジェムで集中を始める", tableName: "Widgets", comment: "VoiceOver: the small widget, which starts a focus in the app"))
    }

    /// The jar and the heading on top, then one row of equal buttons across
    /// the whole width, so all four free lengths fit even the narrowest
    /// medium widget with a comfortable tap target each.
    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // D19: the raw stone on its own navy plate.
                NeutralJarArtwork(framed: true)
                    .frame(width: 88)

                VStack(alignment: .leading, spacing: 4) {
                    wordmark
                    Text("今日のひと粒を積もう", tableName: "Widgets", comment: "Medium widget heading: an invitation to add today's gem, never pressure")
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .foregroundStyle(WidgetPalette.warmText)
                        .minimumScaleFactor(0.72)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(
                    "ポモジェムを開く",
                    tableName: "Widgets",
                    comment: "VoiceOver: the medium widget's jar and heading, which open the app (its length buttons start a focus)"
                ))
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
            Text("ポモジェム", tableName: "Widgets", comment: "The app's name, in the widget gallery, on the widgets and on the Live Activity")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetPalette.amber)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

}

/// One tap to a focus of a free length: the fixed lengths the Home picker
/// offers everyone. The widget cannot know the length last used in the app.
/// Each button is 44 pt tall, the minimum comfortable tap target, which still
/// leaves the jar and heading room on the narrowest medium widget.
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
                        .frame(maxWidth: .infinity, minHeight: 44)
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

/// D19 (Docs/GemExperienceDesign.md §8.7): the next gem as a still,
/// colourless raw stone — the same picture for everyone, with no account
/// data. In full colour it always sits on opaque deep navy (the widget's
/// background, and in the medium widget a plate of its own), so a light
/// wallpaper never muddies it; a tinted Home Screen draws its own
/// background, so the plate is left out and the facets carry the stone.
private struct NeutralJarArtwork: View {
    /// Draws the stone's own plate (the medium widget's specimen card).
    let framed: Bool

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        RawStoneArtwork(
            showsPlate: framed && renderingMode == .fullColor,
            showsShadow: renderingMode == .fullColor
        )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .configurationDisplayName(Text("ポモジェム", tableName: "Widgets", comment: "The app's name, in the widget gallery, on the widgets and on the Live Activity"))
        .description(Text("集中を始める", tableName: "Widgets", comment: "Widget button text that starts a focus (the app's Start Focus)"))
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
            Label {
                Text("集中を始める", tableName: "Widgets", comment: "Widget button text that starts a focus (the app's Start Focus)")
            } icon: {
                Image(systemName: "circle.grid.3x3.fill")
            }
        case .accessoryCircular:
            VStack(spacing: -2) {
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("集中", tableName: "Widgets", comment: "Lock Screen circular widget: starts a focus (en: Focus)")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text("ポモジェム", tableName: "Widgets", comment: "The app's name, in the widget gallery, on the widgets and on the Live Activity")
                } icon: {
                    Image(systemName: "circle.grid.3x3.fill")
                }
                    .font(.system(size: 11, weight: .semibold))
                Text("集中を始める", tableName: "Widgets", comment: "Widget button text that starts a focus (the app's Start Focus)")
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
