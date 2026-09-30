import Foundation
import Observation
import UIKit

enum WidgetSnapshotStoreError: LocalizedError {
    case accountIdentityUnavailable
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .accountIdentityUnavailable:
            return String(
                localized: "このバージョンではアカウント情報をウィジェットへ共有しません。",
                table: "Focus",
                comment: "Error: this version never shares account data with the widgets"
            )
        case .pngEncodingFailed:
            return String(
                localized: "瓶の画像を保存できませんでした。",
                table: "Focus",
                comment: "Error: the jar image for the widget could not be saved"
            )
        }
    }
}

/// Version 1 fail-closed facade for the former account-scoped Widget publisher.
/// The shipping Widget is an account-neutral launcher: its taps carry constant
/// `pomogem://` routes and it has no App Group. (The host's App Group exists
/// only for the Screen Time monitor, and the Widget must never join it:
/// PRIVACY.md, Scripts/verify-release-archive.sh.) So no image or metadata is
/// encoded, persisted, or handed to WidgetKit.
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
        guard ReleaseExternalSurfacePolicy.showsAccountDataInWidgets else {
            lastSavedAt = nil
            lastErrorDescription = nil
            return
        }
        throw WidgetSnapshotStoreError.accountIdentityUnavailable
    }

    func save(
        imageData: Data,
        metadata: WidgetSnapshotMetadata
    ) async throws {
        guard ReleaseExternalSurfacePolicy.showsAccountDataInWidgets else {
            lastSavedAt = nil
            lastErrorDescription = nil
            return
        }
        throw WidgetSnapshotStoreError.accountIdentityUnavailable
    }

    func loadMetadata() async throws -> WidgetSnapshotMetadata {
        throw WidgetSnapshotStoreError.accountIdentityUnavailable
    }

    func clear() async throws {
        lastSavedAt = nil
        lastErrorDescription = nil
    }
}
