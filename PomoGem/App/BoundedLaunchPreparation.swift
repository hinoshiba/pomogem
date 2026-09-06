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
        /// Session integrity includes source-specific invariants that cannot be
        /// expressed portably by every supported SwiftData predicate runtime.
        /// Scan a small stable page after applying coarse database bounds.
        static let onboardingSessionPageLimit = 32
        static let onboardingSessionMaximumPages = 16
        static let onboardingSessionMaximumRows =
            onboardingSessionPageLimit * onboardingSessionMaximumPages
        static let pendingCompletionLimit = 1
        static let matchingResetMarkerLimit = 1
    }

    struct FetchAudit: Equatable {
        var latestResetMarkerRows = 0
        var prefsOwnedRows = 0
        var prefsPhysicalRows = 0
        var canonicalPrefsRows = 0
        var fallbackPrefsRows = 0
        var canonicalGachaRows = 0
        var fallbackGachaRows = 0
        var onboardingPrefsRows = 0
        var onboardingSessionRows = 0
        var onboardingSessionCandidateRowsScanned = 0
        var onboardingSessionFetches = 0
        var onboardingSessionMaximumPageRows = 0
        var onboardingSessionScanReachedLimit = false
        var onboardingAchievementRows = 0
        var pendingCompletionRows = 0
        var matchingResetMarkerRows = 0

        var maximumRowsReturnedByAnyFetch: Int {
            [
                latestResetMarkerRows,
                prefsOwnedRows,
                prefsPhysicalRows,
                canonicalPrefsRows,
                fallbackPrefsRows,
                canonicalGachaRows,
                fallbackGachaRows,
                onboardingPrefsRows,
                onboardingSessionRows,
                onboardingSessionMaximumPageRows,
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
        pendingCompletionID: UUID?,
        now: Date = .now
    ) throws -> Result {
        var audit = FetchAudit()
        var maintenanceReasons = Set<DeferredMaintenanceReason>()

        let markerRows = try context.fetch(latestResetMarkerDescriptor(now: now))
        audit.latestResetMarkerRows = markerRows.count
        let currentMarker = markerRows.first?.policySnapshot
        let currentEpochID = currentMarker?.epochID

        let prefs = try canonicalPrefs(
            context: context,
            currentEpochID: currentEpochID,
            audit: &audit,
            maintenanceReasons: &maintenanceReasons
        )
        // Prefs belongs to the synchronized store; GachaState below is a local
        // derived cache. Keep their writes on separate save boundaries because
        // a multi-store coordinator cannot promise an atomic cross-store save.
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }
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
        let hasOnboardingSessionEvidence = try hasOnboardingSessionEvidence(
            context: context,
            currentEpochID: currentEpochID,
            now: now,
            audit: &audit
        )
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
            audit: &audit,
            now: now
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
            pendingMaterialized = rows.contains {
                StudySessionIntegrityPolicy.isSupported($0)
                    && ($0.rareRewardRuleVersion != RareRewardLedgerV2.ruleVersion
                        || $0.rareRewardParticipated != nil)
            }
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
                || hasOnboardingSessionEvidence
                || !onboardingAchievements.isEmpty,
            pendingCompletionMaterialized: pendingMaterialized,
            localFocusEpochState: localEpochState,
            localFocusDisposition: localFocusDisposition,
            deferredMaintenanceReasons: maintenanceReasons,
            fetchAudit: audit
        )
    }

    // MARK: - Exact reset ordering

    static func latestResetMarkerDescriptor(
        now: Date = .now
    ) -> FetchDescriptor<ActivityResetMarker> {
        ActivityResetPolicy.currentMarkerDescriptor(
            now: now,
            fetchLimit: QueryContract.latestResetMarkerLimit
        )
    }

    // MARK: - Bounded singleton preparation

    private static func canonicalPrefs(
        context: ModelContext,
        currentEpochID: UUID?,
        audit: inout FetchAudit,
        maintenanceReasons: inout Set<DeferredMaintenanceReason>
    ) throws -> Prefs {
        let preparation = try PrefsSyncPolicy.prepareWriterRowForLaunch(
            context: context,
            currentEpochID: currentEpochID,
            canonicalID: canonicalPrefsID
        )
        audit.prefsOwnedRows = preparation.ownedRowCount
        audit.prefsPhysicalRows = preparation.physicalRowCount
        let writer = preparation.row
        if preparation.created {
            maintenanceReasons.insert(.prefsSingletonCreated)
        } else if writer.id == canonicalPrefsID {
            audit.canonicalPrefsRows = 1
        } else {
            // An existing device-owned row is valid without changing its
            // logical ID. Launch must never rewrite a foreign or legacy row in
            // order to manufacture a singleton.
            audit.fallbackPrefsRows = 1
        }
        return writer
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
        currentEpochID _: UUID?
    ) -> FetchDescriptor<Prefs> {
        // Onboarding is a monotone account fact, not activity-epoch state. A
        // reset changes only daily/manual accounting and must not make a
        // replacement device appear new again.
        var descriptor = FetchDescriptor<Prefs>(
            predicate: #Predicate { $0.hasCompletedOnboarding }
        )
        descriptor.fetchLimit = QueryContract.onboardingEvidenceLimit
        return descriptor
    }

    private static func hasOnboardingSessionEvidence(
        context: ModelContext,
        currentEpochID: UUID?,
        now: Date,
        audit: inout FetchAudit
    ) throws -> Bool {
        var offset = 0
        while offset < QueryContract.onboardingSessionMaximumRows {
            try Task.checkCancellation()
            let remaining = QueryContract.onboardingSessionMaximumRows - offset
            let fetchLimit = min(
                QueryContract.onboardingSessionPageLimit,
                remaining
            )
            var descriptor = onboardingSessionDescriptor(
                currentEpochID: currentEpochID,
                now: now
            )
            descriptor.fetchLimit = fetchLimit
            descriptor.fetchOffset = offset
            let page = try autoreleasepool {
                try context.fetch(descriptor)
            }
            audit.onboardingSessionFetches += 1
            audit.onboardingSessionCandidateRowsScanned += page.count
            audit.onboardingSessionMaximumPageRows = max(
                audit.onboardingSessionMaximumPageRows,
                page.count
            )

            if page.contains(where: {
                StudySessionIntegrityPolicy.isSupported($0, relativeTo: now)
            }) {
                // This is an existence result, not a retained history page.
                audit.onboardingSessionRows = 1
                return true
            }

            guard page.count == fetchLimit else { return false }
            offset += page.count
        }
        audit.onboardingSessionScanReachedLimit = true
        return false
    }

    private static func onboardingSessionDescriptor(
        currentEpochID: UUID?,
        now: Date
    ) -> FetchDescriptor<StudySession> {
        let bounds = StudySessionIntegrityPolicy.supportedDateBounds(
            relativeTo: now
        )
        let earliest = bounds.earliest
        let latest = bounds.latest
        let minimumSeconds = Constants.Timer.secondsPerMinute
        let maximumSeconds = StudySessionIntegrityPolicy.maximumSeconds
        let maximumGrams = StudySessionIntegrityPolicy.maximumGrams
        let predicate: Predicate<StudySession>
        if let currentEpochID {
            predicate = #Predicate {
                $0.dataEpochID == currentEpochID
                    && $0.startAt >= earliest
                    && $0.endAt <= latest
                    && $0.startAt <= $0.endAt
                    && $0.seconds >= minimumSeconds
                    && $0.seconds <= maximumSeconds
                    && $0.grams >= 0
                    && $0.grams <= maximumGrams
            }
        } else {
            predicate = #Predicate {
                $0.dataEpochID == nil
                    && $0.startAt >= earliest
                    && $0.endAt <= latest
                    && $0.startAt <= $0.endAt
                    && $0.seconds >= minimumSeconds
                    && $0.seconds <= maximumSeconds
                    && $0.grams >= 0
                    && $0.grams <= maximumGrams
            }
        }
        return FetchDescriptor<StudySession>(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\StudySession.endAt, order: .reverse),
                SortDescriptor(\StudySession.id, order: .reverse)
            ]
        )
    }

    private static func onboardingAchievementDescriptor(
        currentEpochID: UUID?
    ) -> FetchDescriptor<AchievementStone> {
        // This one active row is only an evidence candidate. `prepare` always
        // follows it with an exact-ID, tombstone-inclusive bounded replica-set
        // lookup, so a late stale duplicate cannot restore onboarding evidence.
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
        audit: inout FetchAudit,
        now: Date
    ) throws -> ActivityEpochState? {
        guard hasLocalFocus else { return nil }
        guard let currentMarker else {
            return localFocusEpochID == nil ? .current : .awaitingMarker
        }
        guard let localFocusEpochID else { return .stale }
        if localFocusEpochID == currentMarker.epochID { return .current }

        let maximumSupportedSequence = ActivityResetPolicy.maximumSupportedSequence
        var descriptor = FetchDescriptor<ActivityResetMarker>(
            predicate: #Predicate {
                $0.epochID == localFocusEpochID
                    && $0.sequence >= 0
                    && $0.sequence <= maximumSupportedSequence
            }
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
