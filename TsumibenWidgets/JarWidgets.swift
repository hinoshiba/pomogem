import Foundation
import SwiftUI
import UIKit
import WidgetKit

private struct JarWidgetEntry: TimelineEntry {
    let date: Date
    let metadata: WidgetSnapshotMetadata
    let imageData: Data?
}

private struct JarTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> JarWidgetEntry {
        JarWidgetEntry(
            date: .now,
            metadata: WidgetSnapshotMetadata(
                totalGrams: 12_750,
                measuredGrams: 12_500,
                pebbleCount: 51,
                goldCount: 3,
                prismCount: 1
            ),
            imageData: nil
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (JarWidgetEntry) -> Void
    ) {
        completion(loadEntry())
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<JarWidgetEntry>) -> Void
    ) {
        let entry = loadEntry()
        let refreshDate = Date.now.addingTimeInterval(
            IntegrationConstants.widgetTimelineRefreshInterval
        )
        completion(Timeline(entries: [entry], policy: .after(refreshDate)))
    }

    private func loadEntry() -> JarWidgetEntry {
        guard let containerURL = IntegrationConstants.appGroupContainerURL() else {
            return JarWidgetEntry(date: .now, metadata: .empty, imageData: nil)
        }

        let metadataURL = containerURL.appendingPathComponent(
            IntegrationConstants.widgetSnapshotMetadataFileName,
            isDirectory: false
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let metadataData = try? Data(contentsOf: metadataURL),
              let metadata = try? decoder.decode(
                  WidgetSnapshotMetadata.self,
                  from: metadataData
              ) else {
            return JarWidgetEntry(date: .now, metadata: .empty, imageData: nil)
        }

        let imageData = metadata.imageURL.flatMap { try? Data(contentsOf: $0) }
        return JarWidgetEntry(
            date: metadata.updatedAt,
            metadata: metadata,
            imageData: imageData
        )
    }
}

struct JarHomeWidget: Widget {
    let kind = IntegrationConstants.homeWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JarTimelineProvider()) { entry in
            JarHomeWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetPalette.backgroundGradient
                }
        }
        .configurationDisplayName("つみべん")
        .description("瓶と積んだ質量")
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
            JarArtwork(imageData: entry.imageData)
                .frame(maxHeight: .infinity)
            massLabel(alignment: .center)
        }
        .padding(12)
    }

    private var mediumLayout: some View {
        HStack(spacing: 16) {
            JarArtwork(imageData: entry.imageData)
                .frame(width: 126)

            VStack(alignment: .leading, spacing: 0) {
                wordmark
                Spacer(minLength: 8)
                Text("積んだ質量")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WidgetPalette.mutedText)
                Text(entry.metadata.formattedTotalMass)
                    .font(.system(size: 29, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(WidgetPalette.warmText)
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label("\(entry.metadata.pebbleCount)", systemImage: "circle.fill")
                    if entry.metadata.goldCount > 0 {
                        Label("\(entry.metadata.goldCount)", systemImage: "sparkles")
                    }
                    if entry.metadata.prismCount > 0 {
                        Label("\(entry.metadata.prismCount)", systemImage: "diamond.fill")
                    }
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(WidgetPalette.mutedText)
                Spacer(minLength: 8)
                Text(entry.metadata.updatedAt, style: .relative)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WidgetPalette.mutedText.opacity(0.75))
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
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

    private func massLabel(alignment: Alignment) -> some View {
        Text(entry.metadata.formattedTotalMass)
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(WidgetPalette.warmText)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: alignment)
            .accessibilityLabel("積んだ質量 \(entry.metadata.formattedTotalMass)")
    }
}

private struct JarArtwork: View {
    let imageData: Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(WidgetPalette.card.opacity(0.62))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(WidgetPalette.glassEdge, lineWidth: 1)

            if let imageData,
               let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "hourglass.bottomhalf.filled")
                        .font(.system(size: 25, weight: .light))
                    Text("まだ空っぽ。")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(WidgetPalette.mutedText)
            }
        }
        .accessibilityHidden(true)
    }
}

struct JarLockScreenWidget: Widget {
    let kind = IntegrationConstants.lockScreenWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JarTimelineProvider()) { entry in
            JarLockScreenView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("つみべん 総質量")
        .description("積んだ総質量")
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
                entry.metadata.formattedTotalMass,
                systemImage: "circle.grid.3x3.fill"
            )
        case .accessoryCircular:
            VStack(spacing: -2) {
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(entry.metadata.formattedTotalMass)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
            }
        default:
            VStack(alignment: .leading, spacing: 2) {
                Label("つみべん", systemImage: "circle.grid.3x3.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(entry.metadata.formattedTotalMass)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .monospacedDigit()
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
