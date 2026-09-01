import Foundation

/// Lightweight state persisted beside the rendered jar PNG in the App Group.
/// WidgetKit deliberately does not read SwiftData, which keeps widget launches
/// fast and makes a missing/iCloud-unavailable model container harmless.
struct WidgetSnapshotMetadata: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    var totalGrams: Int
    var measuredGrams: Int
    var pebbleCount: Int
    var goldCount: Int
    var prismCount: Int
    var updatedAt: Date
    var imageFileName: String

    init(
        totalGrams: Int,
        measuredGrams: Int,
        pebbleCount: Int,
        goldCount: Int,
        prismCount: Int,
        updatedAt: Date = .now,
        imageFileName: String = IntegrationConstants.widgetSnapshotImageFileName
    ) {
        version = Self.currentVersion
        self.totalGrams = max(0, totalGrams)
        self.measuredGrams = max(0, measuredGrams)
        self.pebbleCount = max(0, pebbleCount)
        self.goldCount = max(0, goldCount)
        self.prismCount = max(0, prismCount)
        self.updatedAt = updatedAt
        self.imageFileName = imageFileName
    }

    static let empty = Self(
        totalGrams: 0,
        measuredGrams: 0,
        pebbleCount: 0,
        goldCount: 0,
        prismCount: 0
    )

    var formattedTotalMass: String {
        Self.format(grams: totalGrams)
    }

    var formattedMeasuredMass: String {
        Self.format(grams: measuredGrams)
    }

    var imageURL: URL? {
        IntegrationConstants.appGroupContainerURL()?
            .appendingPathComponent(imageFileName, isDirectory: false)
    }

    private static func format(grams: Int) -> String {
        guard grams >= 1_000 else { return "\(grams)g" }

        let kilograms = Double(grams) / 1_000
        if grams.isMultiple(of: 1_000) {
            return "\(grams / 1_000)kg"
        }

        let formatted = String(format: "%.2f", kilograms)
            .replacingOccurrences(of: "0$", with: "", options: .regularExpression)
        return "\(formatted)kg"
    }
}
