import Foundation
import SwiftData

/// The deliberately small, synchronous part of app launch.
///
/// `SeedData.bootstrap` is a deterministic repair/migration sweep. It is useful
/// after CloudKit delivery, but materializing decades of history before SwiftUI
/// can mount the bottle makes that repair policy a launch-time availability
/// problem. This type performs only indexed singleton/existence reads. Full
/// reconciliation remains a deferred phase owned by `RootView`.
@MainActor
enum BoundedLaunchPreparation {
    static let canonicalPrefsID = UUID(
        uuidString: "7473756D-6962-456E-8000-000000000001"
    )!
    static let canonicalGachaID = UUID(
        uuidString: "7473756D-6962-456E-8000-000000000002"
    )!

    /// Kept explicit so tests can guard the cold-start query budget. A future
    /// launch query must not silently become an unbounded history fetch.
    enum QueryContract {
        static let latestResetMarkerLimit = 1
        static let singletonLimit = 1
        static let onboardingEvidenceLimit = 1
        static let pendingCompletionLimit = 1
        static let matchingResetMarkerLimit = 1
    }

    struct FetchAudit: Equatable {
        var latestResetMarkerRows = 0
        var canonicalPrefsRows = 0
        var fallbackPrefsRows = 0
        var canonicalGachaRows = 0
        var fallbackGachaRows = 0
        var onboardingPrefsRows = 0
        var onboardingSessionRows = 0
        var onboardingAchievementRows = 0
        var pendingCompletionRows = 0
        var matchingResetMarkerRows = 0

        var maximumRowsReturnedByAnyFetch: Int {
            [
                latestResetMarkerRows,
                canonicalPrefsRows,
                fallbackPrefsRows,
                canonicalGachaRows,
                fallbackGachaRows,
                onboardingPrefsRows,
                onboardingSessionRows,
                onboardingAchievementRows,
                pendingCompletionRows,
                matchingResetMarkerRows
            ].max() ?? 0
        }
    }

    enum DeferredMaintenanceReason: Hashable {
        case prefsSingletonCreated
        case prefsSingletonCanonicalized
        case gachaSingletonCreated
        case gachaSingletonCanonicalized
        case localFocusAwaitingResetMarker
    }

    enum LocalFocusDisposition: Equatable {
        case none
        case present
        case quarantineAwaitingMarker
        case retireStale
        case retireMaterialized(sessionID: UUID)
    }

    struct Result {
        let currentMarker: ActivityResetSnapshot?
        let canonicalPrefs: Prefs
        let canonicalGacha: GachaState
        let hasSyncedUsageEvidence: Bool
        /// nil means there was no current-generation pending completion to
        /// resolve. false deliberately keeps the durable local envelope alive.
        let pendingCompletionMaterialized: Bool?
        let localFocusEpochState: ActivityEpochState?
        let localFocusDisposition: LocalFocusDisposition
        /// A typed hand-off to the eventual chunked repair worker. These hints
        /// never authorize an automatic full-store sweep on clean cold launch.
        let deferredMaintenanceReasons: Set<DeferredMaintenanceReason>
        let fetchAudit: FetchAudit
    }

    static func prepare(
        context: ModelContext,
        localFocusEpochID: UUID?,
        hasLocalFocus: Bool,
        pendingCompletionID: UUID?
    ) throws -> Result {
        var audit = FetchAudit()
        var maintenanceReasons = Set<DeferredMaintenanceReason>()

        let markerRows = try context.fetch(latestResetMarkerDescriptor())
        audit.latestResetMarkerRows = markerRows.count
        let currentMarker = markerRows.first?.policySnapshot
        let currentEpochID = currentMarker?.epochID

        let prefs = try canonicalPrefs(
            context: context,
            currentEpochID: currentEpochID,
            audit: &audit,
            maintenanceReasons: &maintenanceReasons
        )
        let gacha = try canonicalGacha(
            context: context,
            currentEpochID: currentEpochID,
            audit: &audit,
            maintenanceReasons: &maintenanceReasons
        )

        let onboardingPrefs = try context.fetch(
            onboardingPrefsDescriptor(currentEpochID: currentEpochID)
        )
        audit.onboardingPrefsRows = onboardingPrefs.count
        let onboardingSessions = try context.fetch(
            onboardingSessionDescriptor(currentEpochID: currentEpochID)
        )
        audit.onboardingSessionRows = onboardingSessions.count
        let onboardingAchievementCandidates = try context.fetch(
            onboardingAchievementDescriptor(currentEpochID: currentEpochID)
        )
        audit.onboardingAchievementRows = onboardingAchievementCandidates.count
        let onboardingAchievements = try AchievementStonePolicy.resolvedVisibleCandidates(
            from: onboardingAchievementCandidates,
            context: context
        )

        let localEpochState = try classifyLocalFocusEpoch(
            localFocusEpochID,
            hasLocalFocus: hasLocalFocus,
            currentMarker: currentMarker,
            context: context,
            audit: &audit
        )
        if localEpochState == .awaitingMarker {
            maintenanceReasons.insert(.localFocusAwaitingResetMarker)
        }

        let pendingMaterialized: Bool?
        if localEpochState == .current, let pendingCompletionID {
            let rows = try context.fetch(pendingCompletionDescriptor(
                sessionID: pendingCompletionID,
                currentEpochID: currentEpochID
            ))
            audit.pendingCompletionRows = rows.count
            pendingMaterialized = !rows.isEmpty
        } else {
            // A completion from an unknown generation remains quarantined. In
            // particular, absence from the current epoch is not permission to
            // retire its last durable local envelope.
            pendingMaterialized = nil
        }

        let localFocusDisposition: LocalFocusDisposition
        switch localEpochState {
        case .current:
            if let pendingCompletionID, pendingMaterialized == true {
                localFocusDisposition = .retireMaterialized(
                    sessionID: pendingCompletionID
                )
            } else {
                localFocusDisposition = .present
            }
        case .stale:
            localFocusDisposition = .retireStale
        case .awaitingMarker:
            localFocusDisposition = .quarantineAwaitingMarker
        case nil:
            localFocusDisposition = .none
        }

        if context.hasChanges {
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }

        return Result(
            currentMarker: currentMarker,
            canonicalPrefs: prefs,
            canonicalGacha: gacha,
            hasSyncedUsageEvidence: !onboardingPrefs.isEmpty
                || !onboardingSessions.isEmpty
                || !onboardingAchievements.isEmpty,
            pendingCompletionMaterialized: pendingMaterialized,
            localFocusEpochState: localEpochState,
            localFocusDisposition: localFocusDisposition,
            deferredMaintenanceReasons: maintenanceReasons,
            fetchAudit: audit
        )
    }

    // MARK: - Exact reset ordering

    static func latestResetMarkerDescriptor() -> FetchDescriptor<ActivityResetMarker> {
        var descriptor = FetchDescriptor<ActivityResetMarker>(sortBy: [
            SortDescriptor(\ActivityResetMarker.resetAt, order: .reverse),
            SortDescriptor(\ActivityResetMarker.sequence, order: .reverse),
            SortDescriptor(\ActivityResetMarker.writerDeviceID, order: .reverse),
            SortDescriptor(\ActivityResetMarker.epochID, order: .reverse),
            SortDescriptor(\ActivityResetMarker.id, order: .reverse)
        ])
        descriptor.fetchLimit = QueryContract.latestResetMarkerLimit
        return descriptor
    }

    // MARK: - Bounded singleton preparation

    private static func canonicalPrefs(
        context: ModelContext,
        currentEpochID: UUID?,
        audit: inout FetchAudit,
        maintenanceReasons: inout Set<DeferredMaintenanceReason>
    ) throws -> Prefs {
        let canonicalRows = try context.fetch(prefsDescriptor(
            id: canonicalPrefsID,
            currentEpochID: currentEpochID
        ))
        audit.canonicalPrefsRows = canonicalRows.count
        if let canonical = canonicalRows.first { return canonical }

        let fallbackRows = try context.fetch(prefsDescriptor(
            id: nil,
            currentEpochID: currentEpochID
        ))
        audit.fallbackPrefsRows = fallbackRows.count
        if let fallback = fallbackRows.first {
            // Do not merge or delete any other record here. Unknown generations
            // and offline duplicates belong to deferred deterministic repair.
            fallback.id = canonicalPrefsID
            fallback.activityEpochID = currentEpochID
            maintenanceReasons.insert(.prefsSingletonCanonicalized)
            return fallback
        }

        let value = Prefs(
            id: canonicalPrefsID,
            activityEpochID: currentEpochID
        )
        context.insert(value)
        maintenanceReasons.insert(.prefsSingletonCreated)
        return value
    }

    private static func canonicalGacha(
        context: ModelContext,
        currentEpochID: UUID?,
        audit: inout FetchAudit,
        maintenanceReasons: inout Set<DeferredMaintenanceReason>
    ) throws -> GachaState {
        let canonicalRows = try context.fetch(gachaDescriptor(
            id: canonicalGachaID,
            currentEpochID: currentEpochID
        ))
        audit.canonicalGachaRows = canonicalRows.count
        if let canonical = canonicalRows.first { return canonical }

        let fallbackRows = try context.fetch(gachaDescriptor(
            id: nil,
            currentEpochID: currentEpochID
        ))
        audit.fallbackGachaRows = fallbackRows.count
        if let fallback = fallbackRows.first {
            // Preserve the synced pity and monotonic reward-mass ledger
            // verbatim. Reconstructing either from a partially delivered
            // session history can regress earned progress.
            fallback.id = canonicalGachaID
            fallback.dataEpochID = currentEpochID
            maintenanceReasons.insert(.gachaSingletonCanonicalized)
            return fallback
        }

        let value = GachaState(
            id: canonicalGachaID,
            dataEpochID: currentEpochID
        )
        context.insert(value)
        maintenanceReasons.insert(.gachaSingletonCreated)
        return value
    }

    private static func prefsDescriptor(
        id: UUID?,
        currentEpochID: UUID?
    ) -> FetchDescriptor<Prefs> {
        let predicate: Predicate<Prefs>
        switch (id, currentEpochID) {
        case let (id?, epochID?):
            predicate = #Predicate { $0.id == id && $0.activityEpochID == epochID }
        case let (id?, nil):
            predicate = #Predicate { $0.id == id && $0.activityEpochID == nil }
        case let (nil, epochID?):
            predicate = #Predicate { $0.activityEpochID == epochID }
        case (nil, nil):
            predicate = #Predicate { $0.activityEpochID == nil }
        }
        var descriptor = FetchDescriptor<Prefs>(
            predicate: predicate,
            sortBy: [SortDescriptor(\Prefs.id)]
        )
        descriptor.fetchLimit = QueryContract.singletonLimit
        return descriptor
    }

    private static func gachaDescriptor(
        id: UUID?,
        currentEpochID: UUID?
    ) -> FetchDescriptor<GachaState> {
        let predicate: Predicate<GachaState>
        switch (id, currentEpochID) {
        case let (id?, epochID?):
            predicate = #Predicate { $0.id == id && $0.dataEpochID == epochID }
        case let (id?, nil):
            predicate = #Predicate { $0.id == id && $0.dataEpochID == nil }
        case let (nil, epochID?):
            predicate = #Predicate { $0.dataEpochID == epochID }
        case (nil, nil):
            predicate = #Predicate { $0.dataEpochID == nil }
        }
        var descriptor = FetchDescriptor<GachaState>(
            predicate: predicate,
            sortBy: [SortDescriptor(\GachaState.id)]
        )
        descriptor.fetchLimit = QueryContract.singletonLimit
        return descriptor
    }

    // MARK: - Bounded onboarding evidence

    private static func onboardingPrefsDescriptor(
        currentEpochID: UUID?
    ) -> FetchDescriptor<Prefs> {
        let predicate: Predicate<Prefs>
        if let currentEpochID {
            predicate = #Predicate {
                $0.activityEpochID == currentEpochID && $0.hasCompletedOnboarding
            }
        } else {
            predicate = #Predicate {
                $0.activityEpochID == nil && $0.hasCompletedOnboarding
            }
        }
        var descriptor = FetchDescriptor<Prefs>(predicate: predicate)
        descriptor.fetchLimit = QueryContract.onboardingEvidenceLimit
        return descriptor
    }

    private static func onboardingSessionDescriptor(
        currentEpochID: UUID?
    ) -> FetchDescriptor<StudySession> {
        let predicate: Predicate<StudySession>
        if let currentEpochID {
            predicate = #Predicate { $0.dataEpochID == currentEpochID }
        } else {
            predicate = #Predicate { $0.dataEpochID == nil }
        }
        var descriptor = FetchDescriptor<StudySession>(predicate: predicate)
        descriptor.fetchLimit = QueryContract.onboardingEvidenceLimit
        return descriptor
    }

    private static func onboardingAchievementDescriptor(
        currentEpochID: UUID?
    ) -> FetchDescriptor<AchievementStone> {
        // This one active row is only an evidence candidate. `prepare` always
        // follows it with an exact-ID, tombstone-inclusive one-row lookup, so a
        // late stale duplicate cannot restore onboarding evidence.
        let predicate: Predicate<AchievementStone>
        if let currentEpochID {
            predicate = #Predicate {
                $0.dataEpochID == currentEpochID && $0.deletedAt == nil
            }
        } else {
            predicate = #Predicate { $0.dataEpochID == nil && $0.deletedAt == nil }
        }
        var descriptor = FetchDescriptor<AchievementStone>(predicate: predicate)
        descriptor.fetchLimit = QueryContract.onboardingEvidenceLimit
        return descriptor
    }

    // MARK: - Local focus quarantine and exact materialization

    private static func classifyLocalFocusEpoch(
        _ localFocusEpochID: UUID?,
        hasLocalFocus: Bool,
        currentMarker: ActivityResetSnapshot?,
        context: ModelContext,
        audit: inout FetchAudit
    ) throws -> ActivityEpochState? {
        guard hasLocalFocus else { return nil }
        guard let currentMarker else {
            return localFocusEpochID == nil ? .current : .awaitingMarker
        }
        guard let localFocusEpochID else { return .stale }
        if localFocusEpochID == currentMarker.epochID { return .current }

        var descriptor = FetchDescriptor<ActivityResetMarker>(
            predicate: #Predicate { $0.epochID == localFocusEpochID }
        )
        descriptor.fetchLimit = QueryContract.matchingResetMarkerLimit
        let matchingRows = try context.fetch(descriptor)
        audit.matchingResetMarkerRows = matchingRows.count
        return matchingRows.isEmpty ? .awaitingMarker : .stale
    }

    private static func pendingCompletionDescriptor(
        sessionID: UUID,
        currentEpochID: UUID?
    ) -> FetchDescriptor<StudySession> {
        let predicate: Predicate<StudySession>
        if let currentEpochID {
            predicate = #Predicate {
                $0.id == sessionID && $0.dataEpochID == currentEpochID
            }
        } else {
            predicate = #Predicate {
                $0.id == sessionID && $0.dataEpochID == nil
            }
        }
        var descriptor = FetchDescriptor<StudySession>(predicate: predicate)
        descriptor.fetchLimit = QueryContract.pendingCompletionLimit
        return descriptor
    }
}
