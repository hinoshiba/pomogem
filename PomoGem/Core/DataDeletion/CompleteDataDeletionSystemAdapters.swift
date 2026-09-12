import Foundation
import SwiftData
import UserNotifications

enum CompleteDataDeletionSystemError: LocalizedError {
    case userDefaultsNotEmpty
    case unsafePersistentStoreURL
    case persistentStoreArtifactRemains
    case cloudPersistenceRequired

    var errorDescription: String? {
        switch self {
        case .userDefaultsNotEmpty:
            return "端末設定を完全に削除できませんでした。"
        case .unsafePersistentStoreURL:
            return "保存領域の場所を安全に検証できなかったため、削除を停止しました。"
        case .persistentStoreArtifactRemains:
            return "この端末の古い保存ファイルを完全に消去できませんでした。"
        case .cloudPersistenceRequired:
            return "iCloud同期を利用している実機でのみ、iCloudを含む完全削除を実行できます。"
        }
    }
}

/// Removes only the exact SwiftData store URLs produced by the shipping
/// ModelConfigurations and their known SQLite/Core Data sidecars. Callers must
/// pass configuration URLs, never a directory discovered from user input.
enum CompleteDataDeletionPersistentStoreCleaner {
    static func removeStores(
        at storeURLs: [URL],
        fileManager: FileManager = .default
    ) throws {
        let uniqueURLs = Set(storeURLs.map(\.standardizedFileURL))
        guard !uniqueURLs.isEmpty else {
            throw CompleteDataDeletionSystemError.unsafePersistentStoreURL
        }

        var existingArtifacts: [URL] = []
        for storeURL in uniqueURLs {
            try validateStoreURL(storeURL)
            for artifact in artifacts(for: storeURL) {
                guard artifactExists(artifact, fileManager: fileManager) else { continue }
                let values = try artifact.resourceValues(forKeys: [
                    .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey
                ])
                let hasExpectedType = artifact.hasDirectoryPath
                    ? values.isDirectory == true
                    : values.isRegularFile == true
                guard values.isSymbolicLink != true, hasExpectedType else {
                    throw CompleteDataDeletionSystemError.unsafePersistentStoreURL
                }
                existingArtifacts.append(artifact)
            }
        }
        // Validate every companion before deleting anything. A malformed or
        // linked sidecar must not leave the otherwise valid primary store gone.
        for artifact in existingArtifacts {
            try fileManager.removeItem(at: artifact)
        }

        let remains = uniqueURLs.contains { storeURL in
            artifacts(for: storeURL).contains {
                artifactExists($0, fileManager: fileManager)
            }
        }
        guard !remains else {
            throw CompleteDataDeletionSystemError.persistentStoreArtifactRemains
        }
    }

    static func removeExactMigrationArtifacts(
        at urls: [URL],
        fileManager: FileManager = .default
    ) throws {
        for rawURL in Set(urls.map(\.standardizedFileURL)) {
            let url = rawURL.standardizedFileURL
            let name = url.lastPathComponent
            guard url.isFileURL,
                  !url.hasDirectoryPath,
                  url.pathComponents.count > 3,
                  name.hasPrefix(".pomogem-local-projection-"),
                  name.hasSuffix(".json"),
                  url.deletingLastPathComponent().path != "/" else {
                throw CompleteDataDeletionSystemError.unsafePersistentStoreURL
            }
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw CompleteDataDeletionSystemError.unsafePersistentStoreURL
            }
            try fileManager.removeItem(at: url)
            guard !fileManager.fileExists(atPath: url.path) else {
                throw CompleteDataDeletionSystemError.persistentStoreArtifactRemains
            }
        }
    }

    static func artifacts(for storeURL: URL) -> [URL] {
        PersistenceStoreArtifactLayout.artifacts(for: storeURL)
    }

    private static func artifactExists(_ url: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func validateStoreURL(_ storeURL: URL) throws {
        guard storeURL.isFileURL,
              !storeURL.hasDirectoryPath,
              storeURL.pathComponents.count > 3,
              storeURL.lastPathComponent.hasSuffix(".store"),
              storeURL.lastPathComponent != ".store"
        else {
            throw CompleteDataDeletionSystemError.unsafePersistentStoreURL
        }

        let parent = storeURL.deletingLastPathComponent().standardizedFileURL
        let processHome = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        ).standardizedFileURL
        guard parent != storeURL,
              parent.path != "/",
              parent != processHome
        else {
            throw CompleteDataDeletionSystemError.unsafePersistentStoreURL
        }
    }
}

/// Deletes every model in the active shipping SwiftData schema and verifies the
/// postcondition before returning. Retained rare-ledger models are visited only
/// by Debug test schemas while the version-one release policy is disabled.
@ModelActor
actor CompleteDataDeletionModelStore: CompleteDataDeletionLocalModelStoring {
    private static let deletionPageSize = 256

    func deleteAllModels() throws -> CompleteDataDeletionModelCounts {
        do {
            // A ModelContainer spans two physical stores. SwiftData does not
            // promise an atomic save across configurations. Its relationship
            // batch-delete also fails on a merged multi-store model, so delete
            // bounded object pages and save within one configuration at a
            // time. The outer journal makes every partial page resumable.
            try deleteCloudModels()
            let afterCloudDelete = try counts()
            guard afterCloudDelete.cloudStoreTotal == 0 else {
                throw CompleteDataDeletionError.invalidState(
                    "iCloud同期対象のローカル行が削除後も残っています"
                )
            }

            try deleteLocalProjectionModels()
            let remaining = try counts()
            guard remaining.localProjectionStoreTotal == 0 else {
                throw CompleteDataDeletionError.invalidState(
                    "端末内の集計行が削除後も残っています"
                )
            }
            return remaining
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func counts() throws -> CompleteDataDeletionModelCounts {
        let rareRewardPendingCommits: Int
        let rareRewardLedgerCursors: Int
        if RareRewardReleasePolicy.isEnabled {
            rareRewardPendingCommits = try modelContext.fetchCount(
                FetchDescriptor<RareRewardPendingCommit>()
            )
            rareRewardLedgerCursors = try modelContext.fetchCount(
                FetchDescriptor<RareRewardLedgerCursor>()
            )
        } else {
            rareRewardPendingCommits = 0
            rareRewardLedgerCursors = 0
        }
        return CompleteDataDeletionModelCounts(
            subjects: try modelContext.fetchCount(FetchDescriptor<Subject>()),
            studySessions: try modelContext.fetchCount(FetchDescriptor<StudySession>()),
            achievementStones: try modelContext.fetchCount(FetchDescriptor<AchievementStone>()),
            aggregatePebbles: try modelContext.fetchCount(FetchDescriptor<AggregatePebble>()),
            legacyStrata: try modelContext.fetchCount(FetchDescriptor<Stratum>()),
            legacyBedrocks: try modelContext.fetchCount(FetchDescriptor<Bedrock>()),
            gachaStates: try modelContext.fetchCount(FetchDescriptor<GachaState>()),
            preferences: try modelContext.fetchCount(FetchDescriptor<Prefs>()),
            activityResetMarkers: try modelContext.fetchCount(
                FetchDescriptor<ActivityResetMarker>()
            ),
            syncedFocusTimers: try modelContext.fetchCount(
                FetchDescriptor<SyncedFocusTimer>()
            ),
            focusTimerDeviceClaims: try modelContext.fetchCount(
                FetchDescriptor<FocusTimerDeviceClaim>()
            ),
            rareRewardPendingCommits: rareRewardPendingCommits,
            rareRewardLedgerCursors: rareRewardLedgerCursors
        )
    }

    private func deleteCloudModels() throws {
        // Delete relationship leaves before Subject. ActivityResetMarker is
        // also removed: the durable post-erasure fence lives in its own
        // CloudKit zone and the file-backed generation receipt.
        try deletePages(of: StudySession.self)
        try deletePages(of: AchievementStone.self)
        try deletePages(of: Prefs.self)
        try deletePages(of: ActivityResetMarker.self)
        try deletePages(of: SyncedFocusTimer.self)
        try deletePages(of: FocusTimerDeviceClaim.self)
        if RareRewardReleasePolicy.isEnabled {
            try deletePages(of: RareRewardPendingCommit.self)
            try deletePages(of: RareRewardLedgerCursor.self)
        }
        try deletePages(of: Subject.self)
    }

    private func deleteLocalProjectionModels() throws {
        try deletePages(of: AggregatePebble.self)
        try deletePages(of: Stratum.self)
        try deletePages(of: Bedrock.self)
        try deletePages(of: GachaState.self)
    }

    private func deletePages<Model: PersistentModel>(
        of _: Model.Type
    ) throws {
        while true {
            try Task.checkCancellation()
            var descriptor = FetchDescriptor<Model>()
            descriptor.fetchLimit = Self.deletionPageSize
            let rows = try modelContext.fetch(descriptor)
            guard !rows.isEmpty else { return }
            for row in rows { modelContext.delete(row) }
            try modelContext.save()
        }
    }
}

struct CompleteDataDeletionArtifactCounts: Equatable, Sendable {
    let exportDirectories: Int
    let animatedGIFs: Int
    let appGroupEntries: Int
}

/// Removes only namespaces owned by this app. It never follows arbitrary paths
/// from share callbacks and never deletes the temporary-directory root or the
/// App Group container itself.
enum CompleteDataDeletionArtifactCleaner {
    /// Shipping version 1 has no App Group. Clear only artifacts created in the
    /// process temporary directory without manufacturing a shared-container
    /// dependency for an otherwise account-neutral Widget.
    static func clearOwnedTemporaryArtifacts(
        temporaryDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> CompleteDataDeletionArtifactCounts {
        let temporaryRoot = temporaryDirectory.standardizedFileURL
        var exportCount = 0
        var gifCount = 0

        let temporaryChildren = try fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        )
        for child in temporaryChildren {
            let values = try child.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isSymbolicLink != true else { continue }
            if values.isDirectory == true, isOwnedExportDirectory(child) {
                try fileManager.removeItem(at: child)
                exportCount += 1
            } else if values.isRegularFile == true,
                      AnimatedShareExporter.isOwnedTemporaryGIF(child) {
                try fileManager.removeItem(at: child)
                gifCount += 1
            }
        }

        // A postcondition scan catches a concurrent writer or failed removal.
        let ownedTemporaryArtifactsRemain = try fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        ).contains { child in
            let values = try child.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey
            ])
            guard values.isSymbolicLink != true else { return false }
            return (values.isDirectory == true && isOwnedExportDirectory(child))
                || (values.isRegularFile == true
                    && AnimatedShareExporter.isOwnedTemporaryGIF(child))
        }
        guard !ownedTemporaryArtifactsRemain else {
            throw CocoaError(.fileWriteUnknown)
        }

        return CompleteDataDeletionArtifactCounts(
            exportDirectories: exportCount,
            animatedGIFs: gifCount,
            appGroupEntries: 0
        )
    }

    /// Test/migration helper retained for inspecting pre-release App Group
    /// artifacts. The live shipping adapter does not call this overload.
    static func clearAllOwnedArtifacts(
        temporaryDirectory: URL,
        appGroupContainerURL: URL,
        fileManager: FileManager = .default
    ) throws -> CompleteDataDeletionArtifactCounts {
        let temporaryCounts = try clearOwnedTemporaryArtifacts(
            temporaryDirectory: temporaryDirectory,
            fileManager: fileManager
        )
        let appGroupRoot = appGroupContainerURL.standardizedFileURL
        var appGroupCount = 0

        let appGroupChildren = try fileManager.contentsOfDirectory(
            at: appGroupRoot,
            includingPropertiesForKeys: nil,
            options: []
        )
        for child in appGroupChildren {
            guard child.standardizedFileURL.deletingLastPathComponent() == appGroupRoot else {
                continue
            }
            try fileManager.removeItem(at: child)
            appGroupCount += 1
        }

        let appGroupEntriesRemain = try fileManager.contentsOfDirectory(
            at: appGroupRoot,
            includingPropertiesForKeys: nil,
            options: []
        ).isEmpty == false
        guard !appGroupEntriesRemain else {
            throw CocoaError(.fileWriteUnknown)
        }

        return CompleteDataDeletionArtifactCounts(
            exportDirectories: temporaryCounts.exportDirectories,
            animatedGIFs: temporaryCounts.animatedGIFs,
            appGroupEntries: appGroupCount
        )
    }

    private static func isOwnedExportDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix(PomoGemDataExportPolicy.directoryPrefix) else {
            return false
        }
        let suffix = String(name.dropFirst(PomoGemDataExportPolicy.directoryPrefix.count))
        return UUID(uuidString: suffix) != nil
    }
}

@MainActor
enum CompleteDataDeletionDefaultsCleaner {
    static func clear(
        defaults: UserDefaults?,
        persistentDomainName: String?
    ) throws {
        guard let defaults else { return }
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
        if let persistentDomainName {
            defaults.removePersistentDomain(forName: persistentDomainName)
            if defaults.persistentDomain(forName: persistentDomainName)?.isEmpty == false {
                throw CompleteDataDeletionSystemError.userDefaultsNotEmpty
            }
        }
    }
}

/// Live adapter for non-SwiftData state. The caller-provided quiescence closure
/// is mandatory because only the root UI owns navigation, timers and writers.
@MainActor
final class SystemCompleteDataDeletionDeviceState: CompleteDataDeletionDeviceStateClearing {
    typealias Quiescence = @MainActor @Sendable () async throws -> Void

    private let quiescence: Quiescence
    private let notificationCenter: UNUserNotificationCenter
    private let standardDefaults: UserDefaults
    private let standardDefaultsDomain: String?
    private let temporaryDirectory: URL

    init(
        quiescence: @escaping Quiescence,
        notificationCenter: UNUserNotificationCenter = .current(),
        standardDefaults: UserDefaults = .standard,
        standardDefaultsDomain: String? = Bundle.main.bundleIdentifier,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.quiescence = quiescence
        self.notificationCenter = notificationCenter
        self.standardDefaults = standardDefaults
        self.standardDefaultsDomain = standardDefaultsDomain
        self.temporaryDirectory = temporaryDirectory
    }

    func quiesceApplication() async throws {
        try await quiescence()
    }

    func clearDeviceState() async throws {
        // Invalidate in-flight adds before clearing OS state so a suspended
        // timer/return-reminder request cannot reappear after deletion.
        await NotificationManager.shared.cancelAllTimerNotifications()
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()
        try await notificationCenter.setBadgeCount(0)
        await FocusActivityManager.shared.endAll()

        _ = try CompleteDataDeletionArtifactCleaner.clearOwnedTemporaryArtifacts(
            temporaryDirectory: temporaryDirectory
        )

        try CompleteDataDeletionDefaultsCleaner.clear(
            defaults: standardDefaults,
            persistentDomainName: standardDefaultsDomain
        )
    }
}
