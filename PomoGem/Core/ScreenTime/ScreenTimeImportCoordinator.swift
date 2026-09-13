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
                seconds: 600, source: .screenTime, grams: 100, relativeTo: now
            ) else { throw ImportError.invalidReceipt }
            let id = receipt.id
            var descriptor = FetchDescriptor<StudySession>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 16
            let existing = try context.fetch(descriptor)
            if !existing.isEmpty {
                guard existing.allSatisfy({
                    $0.source == .screenTime && $0.seconds == 600 && $0.grams == 100
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
            context.insert(StudySession(
                id: receipt.id, subject: subject,
                startAt: receipt.startedAt, endAt: receipt.endedAt,
                seconds: 600, source: .screenTime, grams: 100,
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
