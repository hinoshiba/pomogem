import Foundation
import SwiftData

/// Stable, lossless export of every model stored by PomoGem.
///
/// The file is intentionally written one record at a time. A long-lived account
/// can contain hundreds of thousands of sessions, so constructing a Codable
/// object graph in memory would make the user-facing export action unreliable.
enum PomoGemDataExportPolicy {
    static let format = "jp.hinoshiba.pomogem.user-data"
    static let schemaVersion = 3
    static let batchSize = 256
    static let staleFileAge: TimeInterval = 24 * 60 * 60

    static let directoryPrefix = "pomogem-data-export-"
    fileprivate static let partialFilename = "pomogem-data.partial"
}

struct PomoGemDataExportAppInfo: Codable, Equatable, Sendable {
    let version: String
    let build: String
}

struct PomoGemDataExportRecordCounts: Codable, Equatable, Sendable {
    let subjects: Int
    let studySessions: Int
    let achievementStones: Int
    let aggregatePebbles: Int
    let legacyStrata: Int
    let legacyBedrocks: Int
    let gachaStates: Int
    let preferences: Int
    let activityResetMarkers: Int
    let syncedFocusTimers: Int
    let focusTimerDeviceClaims: Int
    let rareRewardPendingCommits: Int
    let rareRewardLedgerCursors: Int

    var total: Int {
        subjects
            + studySessions
            + achievementStones
            + aggregatePebbles
            + legacyStrata
            + legacyBedrocks
            + gachaStates
            + preferences
            + activityResetMarkers
            + syncedFocusTimers
            + focusTimerDeviceClaims
            + rareRewardPendingCommits
            + rareRewardLedgerCursors
    }
}

struct PomoGemDataExportProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case writing(collectionName: String)
        case finishing
    }

    let phase: Phase
    let completedRecords: Int
    let estimatedTotalRecords: Int

    var fractionCompleted: Double {
        guard estimatedTotalRecords > 0 else {
            return phase == .finishing ? 1 : 0
        }
        return min(1, Double(completedRecords) / Double(estimatedTotalRecords))
    }

    var accessibilityDescription: String {
        switch phase {
        case .preparing:
            return "データを書き出す準備中"
        case let .writing(collectionName):
            guard estimatedTotalRecords > 0 else {
                return "\(collectionName)を書き出し中"
            }
            return "\(collectionName)を書き出し中、\(estimatedTotalRecords)件中\(completedRecords)件"
        case .finishing:
            return "データの書き出しを仕上げています"
        }
    }
}

struct PomoGemDataExportResult: Equatable, Sendable {
    let fileURL: URL
    let recordCounts: PomoGemDataExportRecordCounts
    let exportedAt: Date
}

enum PomoGemDataExporter {
    /// Removes an export created in this process-owned temporary namespace.
    /// Arbitrary URLs are deliberately ignored so a malformed share callback
    /// can never turn cleanup into a broad delete operation.
    static func removeExport(at fileURL: URL) throws {
        guard let directory = ownedTemporaryDirectory(containing: fileURL) else {
            return
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            try manager.removeItem(at: directory)
        }
    }

    /// Cleans up a share sheet that was abandoned by an OS interruption.
    /// Normal exports are deleted as soon as the system share sheet closes.
    @discardableResult
    static func removeStaleTemporaryExports(
        now: Date = .now,
        olderThan age: TimeInterval = PomoGemDataExportPolicy.staleFileAge
    ) throws -> Int {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .creationDateKey,
            .contentModificationDateKey
        ]
        let children = try manager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        var removed = 0
        for child in children where isOwnedDirectoryName(child.lastPathComponent) {
            let values = try child.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let timestamp = values.contentModificationDate ?? values.creationDate ?? .distantFuture
            guard now.timeIntervalSince(timestamp) >= max(0, age) else { continue }
            try manager.removeItem(at: child)
            removed += 1
        }
        return removed
    }

    private static func ownedTemporaryDirectory(containing fileURL: URL) -> URL? {
        let root = FileManager.default.temporaryDirectory.standardizedFileURL
        let file = fileURL.standardizedFileURL
        let directory = file.deletingLastPathComponent()
        guard directory.deletingLastPathComponent() == root,
              isOwnedDirectoryName(directory.lastPathComponent)
        else { return nil }
        return directory
    }

    private static func isOwnedDirectoryName(_ name: String) -> Bool {
        guard name.hasPrefix(PomoGemDataExportPolicy.directoryPrefix) else { return false }
        let suffix = String(name.dropFirst(PomoGemDataExportPolicy.directoryPrefix.count))
        return UUID(uuidString: suffix) != nil
    }
}

@ModelActor
actor PomoGemDataExportWorker {
    typealias ProgressHandler = @Sendable (PomoGemDataExportProgress) -> Void

    func export(
        appInfo: PomoGemDataExportAppInfo,
        exportedAt: Date = .now,
        destinationRoot: URL? = nil,
        includesRetainedRareRewardModels: Bool = RareRewardReleasePolicy.isEnabled,
        progress: ProgressHandler = { _ in }
    ) throws -> PomoGemDataExportResult {
        try Task.checkCancellation()
        let shouldIncludeRetainedRareRewardModels = RareRewardReleasePolicy
            .permitsInternalTestOverride(includesRetainedRareRewardModels)
        progress(PomoGemDataExportProgress(
            phase: .preparing,
            completedRecords: 0,
            estimatedTotalRecords: 0
        ))

        let estimatedCounts = try fetchRecordCounts(
            includesRetainedRareRewardModels: shouldIncludeRetainedRareRewardModels
        )
        let estimatedTotal = estimatedCounts.total
        let manager = FileManager.default
        let root = (destinationRoot ?? manager.temporaryDirectory).standardizedFileURL
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        let exportDirectory = root.appendingPathComponent(
            PomoGemDataExportPolicy.directoryPrefix + UUID().uuidString.lowercased(),
            isDirectory: true
        )
        let protectedAttributes: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.complete
        ]
        try manager.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: false,
            attributes: protectedAttributes
        )
        let partialURL = exportDirectory.appendingPathComponent(
            PomoGemDataExportPolicy.partialFilename,
            isDirectory: false
        )
        let finalURL = exportDirectory.appendingPathComponent(
            Self.filename(for: exportedAt),
            isDirectory: false
        )

        guard manager.createFile(
            atPath: partialURL.path,
            contents: nil,
            attributes: protectedAttributes
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var handle: FileHandle?
        do {
            let openedHandle = try FileHandle(forWritingTo: partialURL)
            handle = openedHandle
            let encoder = Self.makeEncoder()
            var completed = 0

            try Self.write("{\"format\":", to: openedHandle)
            try Self.writeEncoded(PomoGemDataExportPolicy.format, encoder: encoder, to: openedHandle)
            try Self.write(",\"schemaVersion\":\(PomoGemDataExportPolicy.schemaVersion)", to: openedHandle)
            try Self.write(",\"exportedAt\":", to: openedHandle)
            try Self.writeEncoded(exportedAt, encoder: encoder, to: openedHandle)
            try Self.write(",\"dateEncoding\":\"secondsSince1970\"", to: openedHandle)
            try Self.write(",\"binaryEncoding\":\"base64\"", to: openedHandle)
            try Self.write(",\"scope\":\"locallyAvailableSwiftDataStore\"", to: openedHandle)
            try Self.write(",\"app\":", to: openedHandle)
            try Self.writeEncoded(appInfo, encoder: encoder, to: openedHandle)
            try Self.write(",\"records\":{", to: openedHandle)

            let subjectCount = try writeCollection(
                key: "subjects",
                displayName: "テーマ",
                descriptor: FetchDescriptor<Subject>(sortBy: [
                    SortDescriptor(\Subject.createdAt),
                    SortDescriptor(\Subject.id)
                ]),
                encoder: encoder,
                handle: openedHandle,
                completed: &completed,
                estimatedTotal: estimatedTotal,
                progress: progress,
                snapshot: SubjectExportRecord.init
            )
            try Self.write(",", to: openedHandle)
            let sessionCount = try writeCollection(
                key: "studySessions",
                displayName: "集中記録",
                descriptor: FetchDescriptor<StudySession>(sortBy: [
                    SortDescriptor(\StudySession.startAt),
                    SortDescriptor(\StudySession.id)
                ]),
                encoder: encoder,
                handle: openedHandle,
                completed: &completed,
                estimatedTotal: estimatedTotal,
                progress: progress,
                snapshot: StudySessionExportRecord.init
            )
            try Self.write(",", to: openedHandle)
            let achievementCount = try writeCollection(
                key: "achievementStones",
                displayName: "成果の石",
                descriptor: FetchDescriptor<AchievementStone>(sortBy: [
                    SortDescriptor(\AchievementStone.createdAt),
                    SortDescriptor(\AchievementStone.id)
                ]),
                encoder: encoder,
                handle: openedHandle,
                completed: &completed,
                estimatedTotal: estimatedTotal,
                progress: progress,
                snapshot: AchievementStoneExportRecord.init
            )
            try Self.write(",", to: openedHandle)
            let aggregateCount = try writeCollection(
                key: "aggregatePebbles",
                displayName: "まとまり粒",
                descriptor: FetchDescriptor<AggregatePebble>(sortBy: [
                    SortDescriptor(\AggregatePebble.createdAt),
                    SortDescriptor(\AggregatePebble.id)
                ]),
                encoder: encoder,
                handle: openedHandle,
                completed: &completed,
                estimatedTotal: estimatedTotal,
                progress: progress,
                snapshot: AggregatePebbleExportRecord.init
            )
            try Self.write(",", to: openedHandle)
            let stratumCount = try writeCollection(
                key: "legacyStrata",
                displayName: "旧形式の地層",
                descriptor: FetchDescriptor<Stratum>(sortBy: [
                    SortDescriptor(\Stratum.bakedAt),
                    SortDescriptor(\Stratum.id)
                ]),
                encoder: encoder,
                handle: openedHandle,
                completed: &completed,
                estimatedTotal: estimatedTotal,
                progress: progress,
                snapshot: StratumExportRecord.init
            )
            try Self.write(",", to: openedHandle)
            let bedrockCount = try writeCollection(
                key: "legacyBedrocks",
                displayName: "旧形式の岩盤",
                descriptor: FetchDescriptor<Bedrock>(sortBy: [
                    SortDescriptor(\Bedrock.importedAt),
                    SortDescriptor(\Bedrock.hours)
                ]),
                encoder: encoder,
                handle: openedHandle,
                completed: &completed,
                estimatedTotal: estimatedTotal,
                progress: progress,
                snapshot: BedrockExportRecord.init
            )
            try Self.write(",", to: openedHandle)
            let gachaCount = try writeCollection(
                key: "gachaStates",
                displayName: "旧形式の互換状態",
                descriptor: FetchDescriptor<GachaState>(sortBy: [
                    SortDescriptor(\GachaState.id)
                ]),
                encoder: encoder,
                handle: openedHandle,
                completed: &completed,
                estimatedTotal: estimatedTotal,
                progress: progress,
                snapshot: GachaStateExportRecord.init
            )
            try Self.write(",", to: openedHandle)
            let prefsCount = try writeCollection(
                key: "preferences",
                displayName: "設定",
                descriptor: FetchDescriptor<Prefs>(sortBy: [
                    SortDescriptor(\Prefs.id)
                ]),
                encoder: encoder,
                handle: openedHandle,
                completed: &completed,
                estimatedTotal: estimatedTotal,
                progress: progress,
                snapshot: PrefsExportRecord.init
            )
            try Self.write(",", to: openedHandle)
            let resetCount = try writeCollection(
                key: "activityResetMarkers",
                displayName: "リセット履歴",
                descriptor: FetchDescriptor<ActivityResetMarker>(sortBy: [
                    SortDescriptor(\ActivityResetMarker.resetAt),
                    SortDescriptor(\ActivityResetMarker.id)
                ]),
                encoder: encoder,
                handle: openedHandle,
                completed: &completed,
                estimatedTotal: estimatedTotal,
                progress: progress,
                snapshot: ActivityResetMarkerExportRecord.init
            )
            try Self.write(",", to: openedHandle)
            let timerCount = try writeCollection(
                key: "syncedFocusTimers",
                displayName: "同期タイマー",
                descriptor: FetchDescriptor<SyncedFocusTimer>(sortBy: [
                    SortDescriptor(\SyncedFocusTimer.updatedAt),
                    SortDescriptor(\SyncedFocusTimer.id)
                ]),
                encoder: encoder,
                handle: openedHandle,
                completed: &completed,
                estimatedTotal: estimatedTotal,
                progress: progress,
                snapshot: SyncedFocusTimerExportRecord.init
            )
            try Self.write(",", to: openedHandle)
            let claimCount = try writeCollection(
                key: "focusTimerDeviceClaims",
                displayName: "タイマー端末引き継ぎ",
                descriptor: FetchDescriptor<FocusTimerDeviceClaim>(sortBy: [
                    SortDescriptor(\FocusTimerDeviceClaim.claimedAt),
                    SortDescriptor(\FocusTimerDeviceClaim.id)
                ]),
                encoder: encoder,
                handle: openedHandle,
                completed: &completed,
                estimatedTotal: estimatedTotal,
                progress: progress,
                snapshot: FocusTimerDeviceClaimExportRecord.init
            )
            try Self.write(",", to: openedHandle)
            let rareRewardPendingCount: Int
            if shouldIncludeRetainedRareRewardModels {
                rareRewardPendingCount = try writeCollection(
                    key: "rareRewardPendingCommits",
                    displayName: "保留中の互換データ",
                    descriptor: FetchDescriptor<RareRewardPendingCommit>(sortBy: [
                        SortDescriptor(\RareRewardPendingCommit.createdAt),
                        SortDescriptor(\RareRewardPendingCommit.id)
                    ]),
                    encoder: encoder,
                    handle: openedHandle,
                    completed: &completed,
                    estimatedTotal: estimatedTotal,
                    progress: progress,
                    snapshot: RareRewardPendingCommitExportRecord.init
                )
            } else {
                try Self.write("\"rareRewardPendingCommits\":[]", to: openedHandle)
                rareRewardPendingCount = 0
            }
            try Self.write(",", to: openedHandle)
            let rareRewardCursorCount: Int
            if shouldIncludeRetainedRareRewardModels {
                rareRewardCursorCount = try writeCollection(
                    key: "rareRewardLedgerCursors",
                    displayName: "互換台帳の同期位置",
                    descriptor: FetchDescriptor<RareRewardLedgerCursor>(sortBy: [
                        SortDescriptor(\RareRewardLedgerCursor.epochID),
                        SortDescriptor(\RareRewardLedgerCursor.revision),
                        SortDescriptor(\RareRewardLedgerCursor.id)
                    ]),
                    encoder: encoder,
                    handle: openedHandle,
                    completed: &completed,
                    estimatedTotal: estimatedTotal,
                    progress: progress,
                    snapshot: RareRewardLedgerCursorExportRecord.init
                )
            } else {
                try Self.write("\"rareRewardLedgerCursors\":[]", to: openedHandle)
                rareRewardCursorCount = 0
            }

            let actualCounts = PomoGemDataExportRecordCounts(
                subjects: subjectCount,
                studySessions: sessionCount,
                achievementStones: achievementCount,
                aggregatePebbles: aggregateCount,
                legacyStrata: stratumCount,
                legacyBedrocks: bedrockCount,
                gachaStates: gachaCount,
                preferences: prefsCount,
                activityResetMarkers: resetCount,
                syncedFocusTimers: timerCount,
                focusTimerDeviceClaims: claimCount,
                rareRewardPendingCommits: rareRewardPendingCount,
                rareRewardLedgerCursors: rareRewardCursorCount
            )
            progress(PomoGemDataExportProgress(
                phase: .finishing,
                completedRecords: completed,
                estimatedTotalRecords: estimatedTotal
            ))
            try Self.write("},\"recordCounts\":", to: openedHandle)
            try Self.writeEncoded(actualCounts, encoder: encoder, to: openedHandle)
            try Self.write("}", to: openedHandle)
            try openedHandle.synchronize()
            try openedHandle.close()
            handle = nil
            try Task.checkCancellation()
            try manager.moveItem(at: partialURL, to: finalURL)

            return PomoGemDataExportResult(
                fileURL: finalURL,
                recordCounts: actualCounts,
                exportedAt: exportedAt
            )
        } catch {
            try? handle?.close()
            try? manager.removeItem(at: exportDirectory)
            throw error
        }
    }

    private func fetchRecordCounts(
        includesRetainedRareRewardModels: Bool
    ) throws -> PomoGemDataExportRecordCounts {
        let rareRewardPendingCount: Int
        let rareRewardCursorCount: Int
        if includesRetainedRareRewardModels {
            rareRewardPendingCount = try modelContext.fetchCount(
                FetchDescriptor<RareRewardPendingCommit>()
            )
            rareRewardCursorCount = try modelContext.fetchCount(
                FetchDescriptor<RareRewardLedgerCursor>()
            )
        } else {
            rareRewardPendingCount = 0
            rareRewardCursorCount = 0
        }
        return PomoGemDataExportRecordCounts(
            subjects: try modelContext.fetchCount(FetchDescriptor<Subject>()),
            studySessions: try modelContext.fetchCount(FetchDescriptor<StudySession>()),
            achievementStones: try modelContext.fetchCount(FetchDescriptor<AchievementStone>()),
            aggregatePebbles: try modelContext.fetchCount(FetchDescriptor<AggregatePebble>()),
            legacyStrata: try modelContext.fetchCount(FetchDescriptor<Stratum>()),
            legacyBedrocks: try modelContext.fetchCount(FetchDescriptor<Bedrock>()),
            gachaStates: try modelContext.fetchCount(FetchDescriptor<GachaState>()),
            preferences: try modelContext.fetchCount(FetchDescriptor<Prefs>()),
            activityResetMarkers: try modelContext.fetchCount(FetchDescriptor<ActivityResetMarker>()),
            syncedFocusTimers: try modelContext.fetchCount(FetchDescriptor<SyncedFocusTimer>()),
            focusTimerDeviceClaims: try modelContext.fetchCount(FetchDescriptor<FocusTimerDeviceClaim>()),
            rareRewardPendingCommits: rareRewardPendingCount,
            rareRewardLedgerCursors: rareRewardCursorCount
        )
    }

    private func writeCollection<Model, Record>(
        key: String,
        displayName: String,
        descriptor: FetchDescriptor<Model>,
        encoder: JSONEncoder,
        handle: FileHandle,
        completed: inout Int,
        estimatedTotal: Int,
        progress: ProgressHandler,
        snapshot: (Model) -> Record
    ) throws -> Int where Model: PersistentModel, Record: Encodable {
        try Self.write("\"\(key)\":[", to: handle)
        var collectionCount = 0
        try modelContext.enumerate(
            descriptor,
            batchSize: PomoGemDataExportPolicy.batchSize
        ) { model in
            try Task.checkCancellation()
            if collectionCount > 0 {
                try Self.write(",", to: handle)
            }
            try Self.writeEncoded(snapshot(model), encoder: encoder, to: handle)
            collectionCount += 1
            completed += 1
            if collectionCount.isMultiple(of: PomoGemDataExportPolicy.batchSize) {
                progress(PomoGemDataExportProgress(
                    phase: .writing(collectionName: displayName),
                    completedRecords: completed,
                    estimatedTotalRecords: estimatedTotal
                ))
            }
        }
        try Self.write("]", to: handle)
        progress(PomoGemDataExportProgress(
            phase: .writing(collectionName: displayName),
            completedRecords: completed,
            estimatedTotalRecords: estimatedTotal
        ))
        return collectionCount
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.dataEncodingStrategy = .base64
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func write<T: Encodable>(
        _ value: T,
        encoder: JSONEncoder,
        to handle: FileHandle
    ) throws {
        try handle.write(contentsOf: encoder.encode(value))
    }

    private static func writeEncoded<T: Encodable>(
        _ value: T,
        encoder: JSONEncoder,
        to handle: FileHandle
    ) throws {
        try write(value, encoder: encoder, to: handle)
    }

    private static func write(_ string: String, to handle: FileHandle) throws {
        guard let data = string.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try handle.write(contentsOf: data)
    }

    private static func filename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "pomogem-data-\(formatter.string(from: date)).json"
    }
}

private struct SubjectExportRecord: Encodable {
    let id: UUID
    let syncRecordID: UUID
    let contentRevision: Int
    let contentMutationID: UUID
    let name: String
    let colorHex: String
    let sortOrder: Int
    let isArchived: Bool
    let deletedAt: Date?
    let createdAt: Date

    init(_ value: Subject) {
        id = value.id
        syncRecordID = value.syncRecordID
        contentRevision = value.contentRevision
        contentMutationID = value.contentMutationID
        name = value.name
        colorHex = value.colorHex
        sortOrder = value.sortOrder
        isArchived = value.isArchived
        deletedAt = value.deletedAt
        createdAt = value.createdAt
    }
}

private struct StudySessionExportRecord: Encodable {
    let id: UUID
    let syncRecordID: UUID
    let dataEpochID: UUID?
    let subjectID: UUID?
    let subjectIDSnapshot: UUID?
    let subjectNameSnapshot: String
    let subjectColorHexSnapshot: String
    let startAt: Date
    let endAt: Date
    let seconds: Int
    let source: String
    let pebbleKind: String
    let grams: Int
    let deviceDayKey: String
    let rareRewardRuleVersion: Int?
    let rareRewardParticipated: Bool?
    let rareRewardCreditedGrams: Int?
    let rareRewardOutcomesRawValue: String?
    let isBaked: Bool

    init(_ value: StudySession) {
        id = value.id
        syncRecordID = value.syncRecordID
        dataEpochID = value.dataEpochID
        subjectID = value.subject?.id
        subjectIDSnapshot = value.subjectIDSnapshot
        subjectNameSnapshot = value.subjectNameSnapshot
        subjectColorHexSnapshot = value.subjectColorHexSnapshot
        startAt = value.startAt
        endAt = value.endAt
        seconds = value.seconds
        source = value.source.rawValue
        pebbleKind = value.pebbleKind.rawValue
        grams = value.grams
        deviceDayKey = value.deviceDayKey
        rareRewardRuleVersion = value.rareRewardRuleVersion
        rareRewardParticipated = value.rareRewardParticipated
        rareRewardCreditedGrams = value.rareRewardCreditedGrams
        rareRewardOutcomesRawValue = value.rareRewardOutcomesRawValue
        isBaked = value.isBaked
    }
}

private struct AchievementStoneExportRecord: Encodable {
    let id: UUID
    let syncRecordID: UUID
    let dataEpochID: UUID?
    let subjectID: UUID?
    let subjectNameSnapshot: String
    let subjectColorHexSnapshot: String
    let kind: String
    let note: String
    let achievedAt: Date
    let createdAt: Date
    let revision: Int
    let deletedAt: Date?
    let deletionMutationID: UUID?
    let deletionRevision: Int
    let restoredDeletionMutationID: UUID?
    let updatedAt: Date

    init(_ value: AchievementStone) {
        id = value.id
        syncRecordID = value.syncRecordID
        dataEpochID = value.dataEpochID
        subjectID = value.subject?.id
        subjectNameSnapshot = value.subjectNameSnapshot
        subjectColorHexSnapshot = value.subjectColorHexSnapshot
        kind = value.kind.rawValue
        note = value.note
        achievedAt = value.achievedAt
        createdAt = value.createdAt
        revision = value.revision
        deletedAt = value.deletedAt
        deletionMutationID = value.deletionMutationID
        deletionRevision = value.deletionRevision
        restoredDeletionMutationID = value.restoredDeletionMutationID
        updatedAt = value.updatedAt
    }
}

private struct AggregatePebbleExportRecord: Encodable {
    let id: UUID
    let dataEpochID: UUID?
    let createdAt: Date
    let level: Int
    let pebbleCount: Int
    let childAggregateCount: Int
    let grams: Int
    let measuredPebbleCount: Int
    let manualPebbleCount: Int
    let goldPebbleCount: Int
    let prismPebbleCount: Int
    let colorMixJSON: String
    let subjectMixJSON: String
    let periodStart: Date
    let periodEnd: Date
    let sessionIDsJSON: String
    let childAggregateIDsJSON: String
    let parentAggregateID: UUID?

    init(_ value: AggregatePebble) {
        id = value.id
        dataEpochID = value.dataEpochID
        createdAt = value.createdAt
        level = value.level
        pebbleCount = value.pebbleCount
        childAggregateCount = value.childAggregateCount
        grams = value.grams
        measuredPebbleCount = value.measuredPebbleCount
        manualPebbleCount = value.manualPebbleCount
        goldPebbleCount = value.goldPebbleCount
        prismPebbleCount = value.prismPebbleCount
        colorMixJSON = value.colorMixJSON
        subjectMixJSON = value.subjectMixJSON
        periodStart = value.periodStart
        periodEnd = value.periodEnd
        sessionIDsJSON = value.sessionIDsJSON
        childAggregateIDsJSON = value.childAggregateIDsJSON
        parentAggregateID = value.parentAggregateID
    }
}

private struct StratumExportRecord: Encodable {
    let id: UUID
    let dataEpochID: UUID?
    let bakedAt: Date
    let pebbleCount: Int
    let heightPt: Double
    let colorMixJSON: String
    let monthLabel: String
    let sessionIDsJSON: String
    let grams: Int

    init(_ value: Stratum) {
        id = value.id
        dataEpochID = value.dataEpochID
        bakedAt = value.bakedAt
        pebbleCount = value.pebbleCount
        heightPt = value.heightPt
        colorMixJSON = value.colorMixJSON
        monthLabel = value.monthLabel
        sessionIDsJSON = value.sessionIDsJSON
        grams = value.grams
    }
}

private struct BedrockExportRecord: Encodable {
    let dataEpochID: UUID?
    let hours: Int
    let importedAt: Date

    init(_ value: Bedrock) {
        dataEpochID = value.dataEpochID
        hours = value.hours
        importedAt = value.importedAt
    }
}

private struct GachaStateExportRecord: Encodable {
    let id: UUID
    let dataEpochID: UUID?
    let sinceLastGold: Int
    let rewardCreditGrams: Int

    init(_ value: GachaState) {
        id = value.id
        dataEpochID = value.dataEpochID
        sinceLastGold = value.sinceLastGold
        rewardCreditGrams = value.rewardCreditGrams
    }
}

private struct PrefsExportRecord: Encodable {
    let id: UUID
    let syncRecordID: UUID
    let settingsWriterID: String
    let soundRevision: Int
    let soundMutationID: UUID?
    let hapticsRevision: Int
    let hapticsMutationID: UUID?
    let timerCompletionSoundRevision: Int
    let timerCompletionSoundMutationID: UUID?
    let timerCompletionHapticRevision: Int
    let timerCompletionHapticMutationID: UUID?
    let rareRewardRevision: Int
    let rareRewardMutationID: UUID?
    let reminderEnabledRevision: Int
    let reminderEnabledMutationID: UUID?
    let reminderTimeRevision: Int
    let reminderTimeMutationID: UUID?
    let shareIncludesManualRevision: Int
    let shareIncludesManualMutationID: UUID?
    let externalThemeRevision: Int
    let externalThemeMutationID: UUID?
    let keepScreenAwakeRevision: Int
    let keepScreenAwakeMutationID: UUID?
    let preferredFocusMinutesRevision: Int
    let preferredFocusMinutesMutationID: UUID?
    let timerDisplayModeRevision: Int
    let timerDisplayModeMutationID: UUID?
    let usagePurposeRevision: Int
    let usagePurposeMutationID: UUID?
    let activityEpochID: UUID?
    let manualDayKey: String
    let manualUsedToday: Int
    let soundOn: Bool
    let hapticsOn: Bool
    let timerCompletionSoundRawValue: String
    let timerCompletionHapticRawValue: String
    let rareRewardModeRawValue: String
    let rareRewardModeUpdatedAt: Date?
    let reminderEnabled: Bool
    let reminderHour: Int
    let reminderMinute: Int
    let shareIncludesManual: Bool
    let showsThemeNameExternally: Bool
    /// Historical synchronized field, intentionally ignored as an entitlement.
    let legacyIsProIgnored: Bool
    let keepScreenAwake: Bool
    let preferredFocusMinutes: Int
    let preferredFocusSeconds: Int?
    let preferredFocusSecondsMutationID: UUID?
    let timerDisplayModeRawValue: String
    let hasCompletedOnboarding: Bool
    let usagePurposeRawValue: String
    let usagePurposeUpdatedAt: Date?
    let hasEverImportedBedrock: Bool
    let hasCompletedInitialSubjectSeed: Bool

    init(_ value: Prefs) {
        id = value.id
        syncRecordID = value.syncRecordID
        settingsWriterID = value.settingsWriterID
        soundRevision = value.soundRevision
        soundMutationID = value.soundMutationID
        hapticsRevision = value.hapticsRevision
        hapticsMutationID = value.hapticsMutationID
        timerCompletionSoundRevision = value.timerCompletionSoundRevision
        timerCompletionSoundMutationID = value.timerCompletionSoundMutationID
        timerCompletionHapticRevision = value.timerCompletionHapticRevision
        timerCompletionHapticMutationID = value.timerCompletionHapticMutationID
        rareRewardRevision = value.rareRewardRevision
        rareRewardMutationID = value.rareRewardMutationID
        reminderEnabledRevision = value.reminderEnabledRevision
        reminderEnabledMutationID = value.reminderEnabledMutationID
        reminderTimeRevision = value.reminderTimeRevision
        reminderTimeMutationID = value.reminderTimeMutationID
        shareIncludesManualRevision = value.shareIncludesManualRevision
        shareIncludesManualMutationID = value.shareIncludesManualMutationID
        externalThemeRevision = value.externalThemeRevision
        externalThemeMutationID = value.externalThemeMutationID
        keepScreenAwakeRevision = value.keepScreenAwakeRevision
        keepScreenAwakeMutationID = value.keepScreenAwakeMutationID
        preferredFocusMinutesRevision = value.preferredFocusMinutesRevision
        preferredFocusMinutesMutationID = value.preferredFocusMinutesMutationID
        timerDisplayModeRevision = value.timerDisplayModeRevision
        timerDisplayModeMutationID = value.timerDisplayModeMutationID
        usagePurposeRevision = value.usagePurposeRevision
        usagePurposeMutationID = value.usagePurposeMutationID
        activityEpochID = value.activityEpochID
        manualDayKey = value.manualDayKey
        manualUsedToday = value.manualUsedToday
        soundOn = value.soundOn
        hapticsOn = value.hapticsOn
        timerCompletionSoundRawValue = value.timerCompletionSoundRawValue
        timerCompletionHapticRawValue = value.timerCompletionHapticRawValue
        rareRewardModeRawValue = value.rareRewardModeRawValue
        rareRewardModeUpdatedAt = value.rareRewardModeUpdatedAt
        reminderEnabled = value.reminderEnabled
        reminderHour = value.reminderHour
        reminderMinute = value.reminderMinute
        shareIncludesManual = value.shareIncludesManual
        showsThemeNameExternally = value.showsThemeNameExternally
        legacyIsProIgnored = false
        keepScreenAwake = value.keepScreenAwake
        preferredFocusMinutes = value.preferredFocusMinutes
        preferredFocusSeconds = value.preferredFocusSeconds
        preferredFocusSecondsMutationID = value.preferredFocusSecondsMutationID
        timerDisplayModeRawValue = value.timerDisplayModeRawValue
        hasCompletedOnboarding = value.hasCompletedOnboarding
        usagePurposeRawValue = value.usagePurposeRawValue
        usagePurposeUpdatedAt = value.usagePurposeUpdatedAt
        hasEverImportedBedrock = value.hasEverImportedBedrock
        hasCompletedInitialSubjectSeed = value.hasCompletedInitialSubjectSeed
    }
}

private struct ActivityResetMarkerExportRecord: Encodable {
    let id: UUID
    let epochID: UUID
    let sequence: Int
    let resetAt: Date
    let writerDeviceID: String

    init(_ value: ActivityResetMarker) {
        id = value.id
        epochID = value.epochID
        sequence = value.sequence
        resetAt = value.resetAt
        writerDeviceID = value.writerDeviceID
    }
}

private struct SyncedFocusTimerExportRecord: Encodable {
    let id: UUID
    let dataEpochID: UUID?
    let sessionID: UUID
    let statusRaw: String
    let payloadDataBase64: Data
    let startedAt: Date
    let scheduledEndAt: Date?
    let updatedAt: Date
    let terminalAt: Date?
    let revision: Int
    let ownershipSequence: Int
    let writerDeviceID: String

    init(_ value: SyncedFocusTimer) {
        id = value.id
        dataEpochID = value.dataEpochID
        sessionID = value.sessionID
        statusRaw = value.statusRaw
        payloadDataBase64 = value.payloadData
        startedAt = value.startedAt
        scheduledEndAt = value.scheduledEndAt
        updatedAt = value.updatedAt
        terminalAt = value.terminalAt
        revision = value.revision
        ownershipSequence = value.ownershipSequence
        writerDeviceID = value.writerDeviceID
    }
}

private struct FocusTimerDeviceClaimExportRecord: Encodable {
    let id: UUID
    let syncRecordID: UUID
    let dataEpochID: UUID?
    let sessionID: UUID
    let deviceID: String
    let sequence: Int
    let claimedAt: Date
    let releasedAt: Date?

    init(_ value: FocusTimerDeviceClaim) {
        id = value.id
        syncRecordID = value.syncRecordID
        dataEpochID = value.dataEpochID
        sessionID = value.sessionID
        deviceID = value.deviceID
        sequence = value.sequence
        claimedAt = value.claimedAt
        releasedAt = value.releasedAt
    }
}

private struct RareRewardPendingCommitExportRecord: Encodable {
    let id: UUID
    let dataEpochID: UUID?
    let epochID: UUID
    let sessionID: UUID
    let sourceRawValue: String
    let completedSeconds: Int
    let completedGrams: Int
    let modeRawValue: String
    let migrationFingerprint: String
    let migrationTotalCreditedGrams: Int
    let migrationSinceLastGold: Int
    let migrationSeedRawValue: String
    let createdAt: Date

    init(_ value: RareRewardPendingCommit) {
        id = value.id
        dataEpochID = value.dataEpochID
        epochID = value.epochID
        sessionID = value.sessionID
        sourceRawValue = value.sourceRawValue
        completedSeconds = value.completedSeconds
        completedGrams = value.completedGrams
        modeRawValue = value.modeRawValue
        migrationFingerprint = value.migrationFingerprint
        migrationTotalCreditedGrams = value.migrationTotalCreditedGrams
        migrationSinceLastGold = value.migrationSinceLastGold
        migrationSeedRawValue = value.migrationSeedRawValue
        createdAt = value.createdAt
    }
}

private struct RareRewardLedgerCursorExportRecord: Encodable {
    let id: UUID
    let dataEpochID: UUID?
    let epochID: UUID
    let migrationFingerprint: String
    let migrationTotalCreditedGrams: Int
    let migrationSinceLastGold: Int
    let seedRawValue: String
    let totalCreditedGrams: Int
    let creditRemainderGrams: Int
    let nextOrdinal: Int64
    let sinceLastGold: Int
    let revision: Int64
    let updatedAt: Date

    init(_ value: RareRewardLedgerCursor) {
        id = value.id
        dataEpochID = value.dataEpochID
        epochID = value.epochID
        migrationFingerprint = value.migrationFingerprint
        migrationTotalCreditedGrams = value.migrationTotalCreditedGrams
        migrationSinceLastGold = value.migrationSinceLastGold
        seedRawValue = value.seedRawValue
        totalCreditedGrams = value.totalCreditedGrams
        creditRemainderGrams = value.creditRemainderGrams
        nextOrdinal = value.nextOrdinal
        sinceLastGold = value.sinceLastGold
        revision = value.revision
        updatedAt = value.updatedAt
    }
}
