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
            case .invalidReceipt:
                String(localized: "スクリーンタイムの記録を確認できませんでした。", table: "ScreenTime",
                       comment: "Import error: a Screen Time record failed its checks")
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
                // Stored with the row, so it stays a plain literal: rows
                // already written keep the name they were written with.
                subjectNameSnapshot: subject?.safeDisplayName ?? "スクリーンタイムの勉強",
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

    /// Nonisolated because it is a default argument, which is evaluated
    /// outside the enum's main-actor isolation.
    nonisolated static let legacySourceEncodingPageSize = 256

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
    /// `normalizeLegacySourceEncodingIfChanged` skips the scan while this is
    /// unchanged since a recent clean pass.
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

    /// The foreground entry point: one count, and the scan only when the last
    /// clean pass for this store does not vouch for that count. The pass is
    /// kept in device-local defaults because an in-memory memo on the view
    /// would never skip in iCloud mode: PomoGemApp drops the cloud session on
    /// every backgrounding, which rebuilds RootView and its state.
    ///
    /// The count is taken before the scan, so a row that arrives during it
    /// changes the next count and is picked up then. `isStillOwner` is read
    /// after the scan: a pass that ends after the store or account changed
    /// must not vouch for anything. Returns the number of rows rewritten, or
    /// nil when the scan was skipped.
    static func normalizeLegacySourceEncodingIfChanged(
        container: ModelContainer,
        ownerKey: String,
        defaults: UserDefaults = .standard,
        now: Date = .now,
        isStillOwner: () -> Bool
    ) async throws -> Int? {
        let current = ScreenTimeLegacyEncodingCleanPass(
            ownerKey: ownerKey,
            storeIdentity: ScreenTimeLegacyEncodingCleanPass.storeIdentity(of: container),
            candidateCount: try legacySourceEncodingCandidateCount(container: container),
            checkedAt: now
        )
        if ScreenTimeLegacyEncodingCleanPass.load(defaults: defaults)?.vouches(for: current) == true {
            return nil
        }
        let rewritten = try await normalizeLegacySourceEncoding(container: container)
        guard !Task.isCancelled, isStillOwner() else { return rewritten }
        current.save(defaults: defaults)
        return rewritten
    }
}

/// The last clean encoding pass, one per account namespace in device-local
/// defaults (complete data deletion removes it with the rest). An unchanged
/// count is trusted only for `maximumAge`: a deleted row and a late CloudKit
/// arrival between two checks can leave the count equal, and the rescan that
/// then catches the arrival costs no more than the bounded window.
struct ScreenTimeLegacyEncodingCleanPass: Codable, Equatable {
    static let baseKey = "screen-time.legacy-encoding-clean-pass.v1"
    static let maximumAge: TimeInterval = 24 * 60 * 60

    var ownerKey: String
    var storeIdentity: String
    var candidateCount: Int
    var checkedAt: Date

    /// Store file names carry the account or local-only namespace. The
    /// directory is left out: an app's data container path can change across
    /// updates, and a mismatch would only cost one extra scan anyway.
    static func storeIdentity(of container: ModelContainer) -> String {
        container.configurations.map(\.url.lastPathComponent).sorted().joined(separator: "|")
    }

    /// Same owner, same store, same count, and checked recently. A clock set
    /// backwards never reads as recent.
    func vouches(for current: Self) -> Bool {
        let age = current.checkedAt.timeIntervalSince(checkedAt)
        return ownerKey == current.ownerKey
            && storeIdentity == current.storeIdentity
            && candidateCount == current.candidateCount
            && age >= 0 && age < Self.maximumAge
    }

    static func key(defaults: UserDefaults) -> String {
        AccountScopedLocalState.defaultsKey(base: baseKey, defaults: defaults)
    }

    static func load(defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: key(defaults: defaults)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(defaults: defaults))
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
