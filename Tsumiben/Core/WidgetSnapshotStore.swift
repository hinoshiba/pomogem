import Foundation
import Observation
import UIKit
import WidgetKit

enum WidgetSnapshotStoreError: LocalizedError {
    case appGroupUnavailable
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "ウィジェット共有領域を開けませんでした。"
        case .pngEncodingFailed:
            return "瓶の画像を保存できませんでした。"
        }
    }
}

/// Atomically publishes the latest jar render and its display metadata.
/// SwiftData stays in the app process; widgets only consume these two files.
@MainActor
@Observable
final class WidgetSnapshotStore {
    static let shared = WidgetSnapshotStore()

    private(set) var lastSavedAt: Date?
    private(set) var lastErrorDescription: String?

    private init() {}

    func save(
        image: UIImage,
        metadata: WidgetSnapshotMetadata
    ) async throws {
        guard let imageData = image.pngData() else {
            lastErrorDescription = WidgetSnapshotStoreError.pngEncodingFailed.localizedDescription
            throw WidgetSnapshotStoreError.pngEncodingFailed
        }

        try await save(imageData: imageData, metadata: metadata)
    }

    func save(
        imageData: Data,
        metadata: WidgetSnapshotMetadata
    ) async throws {
        do {
            let savedAt = try await Task.detached(priority: .utility) {
                try Self.persist(imageData: imageData, metadata: metadata)
            }.value

            lastSavedAt = savedAt
            lastErrorDescription = nil
            WidgetCenter.shared.reloadTimelines(
                ofKind: IntegrationConstants.homeWidgetKind
            )
            WidgetCenter.shared.reloadTimelines(
                ofKind: IntegrationConstants.lockScreenWidgetKind
            )
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func loadMetadata() async throws -> WidgetSnapshotMetadata {
        try await Task.detached(priority: .utility) {
            try Self.readMetadata()
        }.value
    }

    func clear() async throws {
        do {
            try await Task.detached(priority: .utility) {
                guard let containerURL = IntegrationConstants.appGroupContainerURL() else {
                    throw WidgetSnapshotStoreError.appGroupUnavailable
                }

                let fileManager = FileManager.default
                for fileName in [
                    IntegrationConstants.widgetSnapshotImageFileName,
                    IntegrationConstants.widgetSnapshotMetadataFileName
                ] {
                    let url = containerURL.appendingPathComponent(fileName)
                    if fileManager.fileExists(atPath: url.path) {
                        try fileManager.removeItem(at: url)
                    }
                }
            }.value

            lastSavedAt = nil
            lastErrorDescription = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    nonisolated private static func persist(
        imageData: Data,
        metadata: WidgetSnapshotMetadata
    ) throws -> Date {
        guard let containerURL = IntegrationConstants.appGroupContainerURL() else {
            throw WidgetSnapshotStoreError.appGroupUnavailable
        }

        let savedAt = Date.now
        var currentMetadata = metadata
        currentMetadata.updatedAt = savedAt
        currentMetadata.imageFileName = IntegrationConstants.widgetSnapshotImageFileName

        let imageURL = containerURL.appendingPathComponent(
            IntegrationConstants.widgetSnapshotImageFileName,
            isDirectory: false
        )
        let metadataURL = containerURL.appendingPathComponent(
            IntegrationConstants.widgetSnapshotMetadataFileName,
            isDirectory: false
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let metadataData = try encoder.encode(currentMetadata)

        try imageData.write(to: imageURL, options: .atomic)
        try metadataData.write(to: metadataURL, options: .atomic)
        return savedAt
    }

    nonisolated private static func readMetadata() throws -> WidgetSnapshotMetadata {
        guard let containerURL = IntegrationConstants.appGroupContainerURL() else {
            throw WidgetSnapshotStoreError.appGroupUnavailable
        }

        let metadataURL = containerURL.appendingPathComponent(
            IntegrationConstants.widgetSnapshotMetadataFileName,
            isDirectory: false
        )
        let data = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WidgetSnapshotMetadata.self, from: data)
    }
}
