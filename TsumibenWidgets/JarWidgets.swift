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
    static let homeKind = "TsumibenJarWidget"
    static let lockScreenKind = "TsumibenMassWidget"
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
        .configurationDisplayName("つみべん")
        .description("今日の集中を始める")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

private struct JarHomeWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: JarWidgetEntry

    var body: some View {
        switch family {
        case .systemMedium:
            mediumLayout
        default:
            smallLayout
        }
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
        .accessibilityLabel("つみべんで集中を始める")
    }

    private var mediumLayout: some View {
        HStack(spacing: 16) {
            NeutralJarArtwork()
                .frame(width: 126)

            VStack(alignment: .leading, spacing: 0) {
                wordmark
                Spacer(minLength: 8)
                Text("今日のひと粒を積もう")
                    .font(.system(size: 23, weight: .heavy, design: .rounded))
                    .foregroundStyle(WidgetPalette.warmText)
                    .minimumScaleFactor(0.72)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Label("タップしてアプリを開く", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(WidgetPalette.mutedText)
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("つみべんで今日の集中を始める")
    }

    private var wordmark: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(WidgetPalette.amber)
                .frame(width: 7, height: 7)
                .shadow(color: WidgetPalette.amber.opacity(0.7), radius: 4)
            Text("つみべん")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(WidgetPalette.amber)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
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
        .configurationDisplayName("つみべん")
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
                Label("つみべん", systemImage: "circle.grid.3x3.fill")
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
