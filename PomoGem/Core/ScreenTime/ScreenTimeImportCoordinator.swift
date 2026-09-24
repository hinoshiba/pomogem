import Foundation
import SwiftData

/// The interval is the observation window, not a reconstructed app launch.
struct ScreenTimeLearningImport: Equatable {
    let id: UUID
    let themeID: UUID?
    let startedAt: Date
    let endedAt: Date
    let contextKey: String
    let dataEpochID: UUID?
}

@MainActor
enum ScreenTimeImportCoordinator {
    enum ImportError: LocalizedError {
        case contextChanged, invalidReceipt, conflictingRecord
        var errorDescription: String? {
            switch self {
            case .contextChanged: "記録の保存先が変わりました。もう一度開いてください。"
            case .invalidReceipt: "Screen Timeの記録を確認できませんでした。"
            case .conflictingRecord: "同じ記録の内容が一致しないため、追加を保留しています。"
            }
        }
    }

    /// Use a dedicated context so a failed import cannot roll back an editor.
    /// The caller acknowledges receipts only after this transaction succeeds.
    static func insert(
        _ receipts: [ScreenTimeLearningImport],
        container: ModelContainer,
        contextKey: String,
        dataEpochID: UUID?,
        now: Date = .now
    ) throws -> [UUID] {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        if #available(iOS 18.0, *) {
            context.author = SyncMaintenanceNotificationPolicy.uiAuthor
        }
        let epoch = try context.fetch(ActivityResetPolicy.currentMarkerDescriptor())
            .first?.epochID
        guard epoch == dataEpochID else { throw ImportError.contextChanged }
        var inserted: [UUID] = []
        for receipt in receipts {
            guard receipt.contextKey == contextKey, receipt.dataEpochID == epoch else {
                throw ImportError.contextChanged
            }
            guard StudySessionIntegrityPolicy.isSupported(
                startAt: receipt.startedAt, endAt: receipt.endedAt,
                seconds: SessionSource.screenTimeSeconds, source: .screenTime,
                grams: SessionSource.screenTimeGrams, relativeTo: now
            ) else { throw ImportError.invalidReceipt }
            let id = receipt.id
            var descriptor = FetchDescriptor<StudySession>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 16
            let existing = try context.fetch(descriptor)
            if !existing.isEmpty {
                // `effectiveSource` accepts both the stored `.manual` signature
                // and a row a pre-release build stored as `screenTime`.
                guard existing.allSatisfy({
                    $0.effectiveSource == .screenTime
                        && SessionSource.hasScreenTimeSignature(seconds: $0.seconds, grams: $0.grams)
                        && $0.dataEpochID == epoch && $0.subjectIDSnapshot == receipt.themeID
                }) else { throw ImportError.conflictingRecord }
                continue
            }
            var subject: Subject?
            if let themeID = receipt.themeID {
                var subjects = FetchDescriptor<Subject>(predicate: #Predicate { $0.id == themeID })
                subjects.fetchLimit = SubjectSyncPolicy.maximumPhysicalRows + 1
                subject = SubjectSyncPolicy.canonical(from: try context.fetch(subjects))
            }
            // Persisted as `.manual` with the Screen Time signature (see
            // `SessionSource.persistedEncoding`): 1.0.2 devices on the same
            // iCloud data cannot decode a `screenTime` raw value.
            context.insert(StudySession(
                id: receipt.id, subject: subject,
                startAt: receipt.startedAt, endAt: receipt.endedAt,
                seconds: SessionSource.screenTimeSeconds, source: .screenTime,
                grams: SessionSource.screenTimeGrams,
                deviceDayKey: FairnessPolicy.deviceDayKey(for: receipt.endedAt),
                subjectNameSnapshot: subject?.safeDisplayName ?? "Screen Timeの学習",
                subjectIDSnapshot: receipt.themeID,
                rareRewardRuleVersion: Constants.Gacha.creditRuleVersion,
                rareRewardParticipated: false, rareRewardCreditedGrams: 0,
                rareRewardOutcomesRawValue: "", dataEpochID: epoch
            ))
            inserted.append(receipt.id)
        }
        if context.hasChanges { try context.save() }
        return inserted
    }

    static let legacySourceEncodingPageSize = 256

    /// When a pre-release build could have stored the raw value `screenTime`:
    /// the Screen Time writer first ran on 2026-09-13 (JST), and every build
    /// from the encoding fix on writes `.manual`. A device must not keep
    /// running a pre-release build past the end (Docs/RELEASING.md). Bounding
    /// the scan by `endAt` keeps its cost fixed for the life of the store, so
    /// it can run on every activation and still catch a pre-release row that
    /// CloudKit delivers late, for example after a reinstall.
    static let legacySourceEncodingInterval = DateInterval(
        start: Date(timeIntervalSince1970: 1_789_138_800), // 2026-09-12 00:00 JST
        end: Date(timeIntervalSince1970: 1_796_050_800) // 2026-12-01 00:00 JST
    )

    private static func legacySourceEncodingDescriptor() -> FetchDescriptor<StudySession> {
        let seconds = SessionSource.screenTimeSeconds
        let grams = SessionSource.screenTimeGrams
        let start = legacySourceEncodingInterval.start
        let end = legacySourceEncodingInterval.end
        return FetchDescriptor<StudySession>(
            predicate: #Predicate {
                $0.seconds == seconds && $0.grams == grams
                    && $0.endAt >= start && $0.endAt < end
            },
            sortBy: [SortDescriptor(\StudySession.syncRecordID)]
        )
    }

    /// Rows that could still hold the pre-release value. A single SQL count:
    /// the caller skips the scan while this is unchanged since a clean pass.
    static func legacySourceEncodingCandidateCount(container: ModelContainer) throws -> Int {
        try ModelContext(container).fetchCount(legacySourceEncodingDescriptor())
    }

    /// Pre-release 1.1.0 builds stored Screen Time rows with the raw value
    /// `screenTime`, which a 1.0.2 device on the same iCloud data cannot
    /// decode. This rewrites those rows to the stored `.manual` signature.
    /// For this build it is a no-op (`effectiveSource` is unchanged); CloudKit
    /// then carries the decodable value to every other device.
    ///
    /// Only Screen Time's own writer boundary runs it, with the same guards as
    /// an import: a dedicated UI-authored context in the admitted, selected
    /// store, never during storage switching or data deletion, and never from
    /// background maintenance, whose source resolvers do not rewrite rows.
    /// `Int` and `Date` predicates narrow the scan to 600 s / 100 g rows in
    /// `legacySourceEncodingInterval`; an enum cannot be filtered in the store.
    /// The sort key never changes, so offset pages stay stable while `source`
    /// is rewritten. Each page saves on its own and yields, so the main actor
    /// is never blocked for long. Returns the number of rows rewritten.
    static func normalizeLegacySourceEncoding(
        container: ModelContainer,
        pageSize: Int = legacySourceEncodingPageSize
    ) async throws -> Int {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        if #available(iOS 18.0, *) {
            context.author = SyncMaintenanceNotificationPolicy.uiAuthor
        }
        var descriptor = legacySourceEncodingDescriptor()
        descriptor.fetchLimit = max(1, pageSize)
        var offset = 0
        var normalized = 0
        while true {
            try Task.checkCancellation()
            descriptor.fetchOffset = offset
            let page = try context.fetch(descriptor)
            for row in page where row.normalizeLegacySourceEncoding() {
                normalized += 1
            }
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    context.rollback()
                    throw error
                }
            }
            guard page.count == descriptor.fetchLimit else { return normalized }
            offset += page.count
            await Task.yield()
        }
    }
}

/// Device-local presentation receipts. Saved learning records own the mass;
/// losing an animation receipt can never lose or create learning time.
enum ScreenTimeGemDropStore {
    static let maximumCount = 128
    static func key(defaults: UserDefaults) -> String {
        AccountScopedLocalState.defaultsKey(base: "screen-time.pending-gem-drops.v1", defaults: defaults)
    }
    static func load(defaults: UserDefaults = .standard) -> [UUID] {
        Array((defaults.stringArray(forKey: key(defaults: defaults)) ?? [])
            .compactMap(UUID.init(uuidString:)).prefix(maximumCount))
    }
    static func append(_ ids: [UUID], defaults: UserDefaults = .standard) {
        var seen = Set<UUID>()
        let values = (load(defaults: defaults) + ids).filter { seen.insert($0).inserted }
        defaults.set(Array(values.prefix(maximumCount)).map(\.uuidString), forKey: key(defaults: defaults))
    }
    static func remove(_ id: UUID, defaults: UserDefaults = .standard) {
        defaults.set(load(defaults: defaults).filter { $0 != id }.map(\.uuidString), forKey: key(defaults: defaults))
    }
    static func removeAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(defaults: defaults))
    }
}
