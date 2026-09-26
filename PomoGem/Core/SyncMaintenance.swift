import Foundation
import SwiftData
import SwiftUI

/// Process-local writer identities used only to classify SwiftData save
/// notifications. `ModelContext.author` is available from iOS 18; iOS 17
/// continues to use context identity plus the in-flight worker gate below.
enum SyncMaintenanceNotificationPolicy {
    static let uiAuthor = "com.hinoshiba.pomogem.ui"
    static let maintenanceAuthor = "com.hinoshiba.pomogem.maintenance"

    static let aggregateSourceEntityNames: Set<String> = [
        // PersistentIdentifier.entityName uses SwiftData's model type name.
        // Schema.entityName(for:) is iOS 18+, so keep these explicit while the
        // shipping deployment target remains iOS 17.
        "StudySession",
        "ActivityResetMarker"
    ]
}

enum SyncStoreChangeSource: Equatable, Sendable {
    case modelContextDidSave
    case persistentStoreRemoteChange
}

enum SyncStoreChangeContextOrigin: Equatable, Sendable {
    case mainContext
    case otherContext
    case unavailable
}

/// A framework-neutral notification snapshot. Keeping classification pure
/// makes the iOS 17 fallback and the self-save exclusions regression-testable
/// without constructing private CloudKit mirroring objects.
struct SyncStoreChangeSignal: Equatable, Sendable {
    let source: SyncStoreChangeSource
    let contextOrigin: SyncStoreChangeContextOrigin
    let author: String?
    let changedEntityNames: Set<String>
    let invalidatedAllIdentifiers: Bool
    let persistentStoreURL: URL?

    init(
        source: SyncStoreChangeSource,
        contextOrigin: SyncStoreChangeContextOrigin = .unavailable,
        author: String? = nil,
        changedEntityNames: Set<String> = [],
        invalidatedAllIdentifiers: Bool = false,
        persistentStoreURL: URL? = nil
    ) {
        self.source = source
        self.contextOrigin = contextOrigin
        self.author = author
        self.changedEntityNames = changedEntityNames
        self.invalidatedAllIdentifiers = invalidatedAllIdentifiers
        self.persistentStoreURL = persistentStoreURL
    }
}

enum SyncStoreChangeClassification: Equatable, Sendable {
    case ignoreLocalWriter
    case ignoreMaintenanceWriter
    case ignoreIrrelevant
    case invalidateSessionDependents
}

enum SyncStoreChangeSchedulingDecision: Equatable, Sendable {
    case ignore
    case enqueueSessionDependents
    case deferRemoteUntilWorkerQuiesces
}

enum SyncStoreChangeSchedulingPolicy {
    static func decision(
        classification: SyncStoreChangeClassification,
        source: SyncStoreChangeSource,
        maintenanceWorkerIsInFlight: Bool
    ) -> SyncStoreChangeSchedulingDecision {
        guard classification == .invalidateSessionDependents else {
            return .ignore
        }
        if source == .persistentStoreRemoteChange,
           maintenanceWorkerIsInFlight {
            return .deferRemoteUntilWorkerQuiesces
        }
        return .enqueueSessionDependents
    }
}

enum SyncDeferredSourceInvalidationPolicy {
    static func shouldConsume(
        isDeferred: Bool,
        maintenanceWorkerIsInFlight: Bool
    ) -> Bool {
        isDeferred && !maintenanceWorkerIsInFlight
    }
}

enum SyncStoreChangeClassifier {
    static func classify(
        _ signal: SyncStoreChangeSignal,
        persistenceMode: PersistenceLaunchMode,
        maintenanceWorkerIsInFlight: Bool,
        expectedCloudSourceStoreURL: URL? = nil
    ) -> SyncStoreChangeClassification {
        guard persistenceMode == .cloudKit else { return .ignoreIrrelevant }

        // This notification is emitted for every write to a store that opts
        // in, including this process's writes. The split topology keeps
        // rebuildable projections in another store, so accept only the exact
        // active account's CloudKit-backed source URL. Unknown and projection
        // URLs fail closed; the recurring verification sweep remains the
        // bounded fallback for any framework notification without a URL.
        if signal.source == .persistentStoreRemoteChange {
            guard let observedURL = signal.persistentStoreURL?
                      .standardizedFileURL,
                  let expectedURL = expectedCloudSourceStoreURL?
                      .standardizedFileURL,
                  observedURL == expectedURL
            else { return .ignoreIrrelevant }
            return .invalidateSessionDependents
        }

        if signal.author == SyncMaintenanceNotificationPolicy.maintenanceAuthor {
            return .ignoreMaintenanceWriter
        }

        if signal.contextOrigin == .otherContext, signal.author == nil {
            // On iOS 17 there is no public ModelContext.author. A worker's
            // synchronous didSave can reach SwiftUI after the await resumes,
            // when `isWorkerInFlight` is already false. Never turn an
            // unidentified secondary-context save into a new generation; the
            // persistent-store remote-change notification and periodic sweep
            // are the authoritative import paths on that OS.
            return .ignoreMaintenanceWriter
        }

        let changedAggregateSource = !signal.changedEntityNames.isDisjoint(
            with: SyncMaintenanceNotificationPolicy.aggregateSourceEntityNames
        )
        if signal.contextOrigin == .mainContext
            || signal.author == SyncMaintenanceNotificationPolicy.uiAuthor {
            // A normal settings/projection save is irrelevant, but a locally
            // completed/edited session invalidates the same summaries as a
            // CloudKit import. Treating that write as work is not a self-loop:
            // the maintenance actor has a separate author/in-flight gate.
            return changedAggregateSource || signal.invalidatedAllIdentifiers
                ? .invalidateSessionDependents
                : .ignoreLocalWriter
        }
        if maintenanceWorkerIsInFlight {
            // iOS 17 has no ModelContext.author. At this point the save is not
            // the main UI context and cannot be distinguished from the active
            // maintenance context. The exact source-store remote notification
            // above and the recurring sweep remain authoritative.
            return .ignoreMaintenanceWriter
        }
        guard changedAggregateSource || signal.invalidatedAllIdentifiers else {
            // In particular, do not treat an unclassified iOS 17 worker save
            // as an import. The remote-change signal and recurring sweep cover
            // imports whose didSave payload is not sufficiently descriptive.
            return .ignoreIrrelevant
        }
        return .invalidateSessionDependents
    }
}

/// Coalesces the paired SwiftData/Core Data notifications normally generated
/// by one CloudKit import. Self-save filtering happens before this gate.
enum SyncStoreChangeDebounceDecision: Equatable, Sendable {
    case ignore
    case acceptNow
    case scheduleTrailing(Date)
}

struct SyncStoreChangeDebouncer: Equatable, Sendable {
    static let productionInterval: TimeInterval = 1

    private(set) var lastAcceptedAt: Date?
    private(set) var trailingDeadline: Date?

    mutating func decision(
        for classification: SyncStoreChangeClassification,
        now: Date = .now,
        interval: TimeInterval = productionInterval
    ) -> SyncStoreChangeDebounceDecision {
        guard classification == .invalidateSessionDependents else {
            return .ignore
        }
        let interval = max(0, interval)
        guard let lastAcceptedAt,
              now.timeIntervalSince(lastAcceptedAt) < interval else {
            self.lastAcceptedAt = now
            trailingDeadline = nil
            return .acceptNow
        }
        let deadline = lastAcceptedAt.addingTimeInterval(interval)
        trailingDeadline = deadline
        return .scheduleTrailing(deadline)
    }

    mutating func consumeTrailing(now: Date = .now) -> Bool {
        guard let trailingDeadline, now >= trailingDeadline else {
            return false
        }
        self.trailingDeadline = nil
        lastAcceptedAt = now
        return true
    }

    mutating func shouldAccept(
        _ classification: SyncStoreChangeClassification,
        now: Date = .now,
        interval: TimeInterval = productionInterval
    ) -> Bool {
        decision(
            for: classification,
            now: now,
            interval: interval
        ) == .acceptNow
    }
}

/// A process-local lease for any cached value derived from aggregate
/// projections. The namespace prevents a durable UI receipt from carrying
/// trust across launches; the monotone epoch prevents a false -> true -> false
/// verification transition from making a pre-import cache current again.
struct AggregateProjectionCacheStamp: Codable, Equatable, Hashable, Sendable {
    let namespace: UUID
    let verificationEpoch: UInt64
}

/// Presentation trust is intentionally process-local. A cloud launch always
/// begins unverified even when yesterday's durable checkpoint was clean: new
/// records may have arrived while this process was not running.
struct AggregateProjectionPresentationContext: Equatable, Sendable {
    let usesCloudPersistence: Bool
    var isVerified: Bool
    private(set) var cacheNamespace: UUID
    private(set) var verificationEpoch: UInt64

    init(
        usesCloudPersistence: Bool,
        isVerified: Bool,
        cacheNamespace: UUID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000000"
        )!,
        verificationEpoch: UInt64 = 0
    ) {
        self.usesCloudPersistence = usesCloudPersistence
        self.isVerified = isVerified
        self.cacheNamespace = cacheNamespace
        self.verificationEpoch = verificationEpoch
    }

    static func initial(for mode: PersistenceLaunchMode) -> Self {
        let usesCloud = mode == .cloudKit
        return Self(
            usesCloudPersistence: usesCloud,
            isVerified: !usesCloud,
            // A cloud projection lease must never survive a process restart.
            // Local-only data has no asynchronous importer, so its stable
            // default namespace preserves legacy/local receipt behaviour.
            cacheNamespace: usesCloud ? UUID() : Self.localCacheNamespace
        )
    }

    static let localVerified = Self(
        usesCloudPersistence: false,
        isVerified: true,
        cacheNamespace: localCacheNamespace
    )

    private static let localCacheNamespace = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    var isCloudVerificationPending: Bool {
        usesCloudPersistence && !isVerified
    }

    var allowsAggregateSummaries: Bool {
        !isCloudVerificationPending
    }

    /// Current epoch regardless of whether it is verified. This is suitable
    /// for a bounded source-page cache that may be presented as a conservative
    /// device-confirmed value while CloudKit verification is pending.
    var currentCacheStamp: AggregateProjectionCacheStamp {
        AggregateProjectionCacheStamp(
            namespace: cacheNamespace,
            verificationEpoch: verificationEpoch
        )
    }

    /// Aggregate-derived caches may only be stamped after verification. A
    /// cache loaded during the pending phase is never promoted implicitly when
    /// the same context later becomes verified.
    var verifiedCacheStamp: AggregateProjectionCacheStamp? {
        isCloudVerificationPending ? nil : currentCacheStamp
    }

    func acceptsCurrentGenerationCache(
        _ stamp: AggregateProjectionCacheStamp?
    ) -> Bool {
        stamp == currentCacheStamp
    }

    func acceptsVerifiedAggregateCache(
        _ stamp: AggregateProjectionCacheStamp?
    ) -> Bool {
        guard let verifiedCacheStamp else { return false }
        return stamp == verifiedCacheStamp
    }

    mutating func invalidate() {
        guard usesCloudPersistence else { return }
        // The practical lifetime of UInt64 generations is far beyond the
        // process lifetime. Still, make exhaustion formally fail-safe: rotate
        // the namespace instead of wrapping into a stamp that could match the
        // first epoch.
        if verificationEpoch < UInt64.max {
            verificationEpoch += 1
        } else {
            cacheNamespace = UUID()
            verificationEpoch = 0
        }
        isVerified = false
    }

    mutating func markVerified() {
        isVerified = true
    }
}

private struct AggregateProjectionPresentationEnvironmentKey: EnvironmentKey {
    static let defaultValue = AggregateProjectionPresentationContext.localVerified
}

extension EnvironmentValues {
    var aggregateProjectionPresentation: AggregateProjectionPresentationContext {
        get { self[AggregateProjectionPresentationEnvironmentKey.self] }
        set { self[AggregateProjectionPresentationEnvironmentKey.self] = newValue }
    }
}

enum AggregateProjectionPresentationPolicy {
    static let cloudPendingNotice =
        "iCloudを確認中です。この端末で確認できた記録だけを表示しています。"

    /// sync-03 (owner-approved, 2026-09-24; narrowed after review of PR #40).
    /// While iCloud verification is pending, the headline mass is a value this
    /// device can stand behind — Home's own sum when it covers every session,
    /// or the last verified total plus newer sessions on this device
    /// (`PendingMassPresentationPolicy`) — with this caption. Otherwise it
    /// stays 「再集計中」, as before: pending hides every aggregate and all but
    /// the newest sessions, so a bare device sum would read as a lost total.
    /// Nothing is written, exported or shared from these values (sharing and
    /// exports still require `allowsAggregateSummaries`), and the verified
    /// value replaces them as soon as verification completes.
    static func verificationCaption(
        context: AggregateProjectionPresentationContext,
        isCloudOfflineSession: Bool
    ) -> String? {
        guard context.isCloudVerificationPending else { return nil }
        return isCloudOfflineSession
            ? String(localized: "このiPhoneの集計を確認中", table: "Storage")
            : String(localized: "iCloudを確認中", table: "Storage",
                     comment: "Caption under the jar's mass while iCloud records are being checked")
    }

    /// The value in place of a mass while pending when this device has none
    /// it can stand behind.
    static var hiddenPendingMassValue: String {
        String(localized: "再集計中", table: "Storage",
               comment: "Jar mass while iCloud is checked and this device cannot show a lifetime total")
    }

    /// `deviceValue` is nil only while pending with nothing to show.
    static func homeMassValue(
        deviceValue: String?,
        context: AggregateProjectionPresentationContext
    ) -> String {
        deviceValue ?? hiddenPendingMassValue
    }

    /// The caller decides the lower bound: the local projection's while
    /// verified, the pending headline's (`PendingMassPresentationPolicy`)
    /// while iCloud is checked — a last verified 「以上」 stays 「以上」.
    static func homeMassUnit(
        verifiedUnit: String,
        hasLocalLowerBound: Bool,
        context: AggregateProjectionPresentationContext
    ) -> String {
        hasLocalLowerBound ? "\(verifiedUnit)以上" : verifiedUnit
    }

    /// The menu's mass metric: the same value as the headline, captioned by
    /// the strip below it while pending; 「再集計中」 when there is none.
    static func menuMassValue(
        formattedMass: String?,
        context: AggregateProjectionPresentationContext
    ) -> String {
        formattedMass ?? hiddenPendingMassValue
    }

    static func homeCountSummary(
        count: Int,
        milestoneSuffix: String,
        hasLocalLowerBound: Bool,
        context: AggregateProjectionPresentationContext
    ) -> String {
        if context.isCloudVerificationPending {
            return "この端末で確認済み \(max(0, count).formatted())粒\(milestoneSuffix)"
        }
        let suffix = hasLocalLowerBound ? "+" : ""
        return "\(max(0, count).formatted())\(suffix)粒\(milestoneSuffix)"
    }

    static func overviewLifetimeValue(
        verifiedValue: String,
        isLocalLowerBound: Bool,
        context: AggregateProjectionPresentationContext
    ) -> String {
        if context.isCloudVerificationPending { return verifiedValue }
        return verifiedValue + (isLocalLowerBound ? "以上" : "")
    }
}

/// Every field that can change aggregate winner selection, membership,
/// displayed totals, colour, or validation trust. Root and Home share this so
/// a bounded @Query change sentinel cannot miss a maintenance re-derivation
/// that leaves the aggregate's identity unchanged.
enum AggregateProjectionChangeFingerprint {
    static func value(for aggregate: AggregatePebble) -> String {
        [
            aggregate.id.uuidString,
            aggregate.dataEpochID?.uuidString ?? "legacy",
            String(aggregate.createdAt.timeIntervalSinceReferenceDate),
            String(aggregate.level),
            String(aggregate.pebbleCount),
            String(aggregate.childAggregateCount),
            String(aggregate.grams),
            String(aggregate.measuredPebbleCount),
            String(aggregate.manualPebbleCount),
            String(aggregate.goldPebbleCount),
            String(aggregate.prismPebbleCount),
            aggregate.colorMixJSON,
            aggregate.subjectMixJSON,
            String(aggregate.periodStart.timeIntervalSinceReferenceDate),
            String(aggregate.periodEnd.timeIntervalSinceReferenceDate),
            aggregate.sessionIDsJSON,
            aggregate.childAggregateIDsJSON,
            aggregate.parentAggregateID?.uuidString ?? "root",
            String(aggregate.projectionValidationVersion)
        ].joined(separator: "|")
    }
}

struct AggregateProjectionVerificationTicket: Equatable, Sendable {
    let verificationSweepGeneration: UInt64

    func isSatisfied(by checkpoint: SyncMaintenanceCheckpoint) -> Bool {
        checkpoint.generation(for: .verificationSweep)
            == verificationSweepGeneration
            && checkpoint.isFullyVerifiedAtCurrentSchema
    }
}

enum SyncMaintenanceCanonicalIDs {
    static let preferences = UUID(
        uuidString: "7473756D-6962-456E-8000-000000000001"
    )!
    static let gacha = UUID(
        uuidString: "7473756D-6962-456E-8000-000000000002"
    )!
}

/// Durable, device-local work categories used after SwiftData has imported
/// CloudKit changes. These are deliberately independent from the small launch
/// hints in `BoundedLaunchPreparation`.
enum SyncMaintenanceKind: String, CaseIterable, Codable, Hashable, Sendable {
    case preferences
    case gacha
    case sessions
    case focusFairness
    case achievements
    case strata
    case aggregates
    case bedrock
    case subjects
    case staleEpochCompaction
    case verificationSweep

    /// Upstream changes invalidate downstream projections. Expanding this at
    /// enqueue time, before a slice starts, prevents a crash from losing work.
    var dependentKinds: Set<Self> {
        switch self {
        case .preferences:
            [self, .bedrock]
        case .gacha:
            [self]
        case .sessions:
            [self, .focusFairness, .strata, .aggregates, .gacha, .subjects]
        case .focusFairness:
            [self, .sessions, .strata, .aggregates, .gacha]
        case .achievements:
            [self, .subjects]
        case .strata:
            [self, .aggregates]
        case .aggregates, .bedrock, .subjects, .staleEpochCompaction:
            [self]
        case .verificationSweep:
            [self]
        }
    }
}

/// A phase-neutral cursor. Phase-specific scalar accumulators are encoded in
/// `payload`; SwiftData model instances never cross the ModelActor boundary.
struct SyncMaintenanceCursor: Codable, Equatable, Sendable {
    var observedWinningEpochID: UUID?
    var phase: Int = 0
    var lastLogicalID: UUID?
    var targetLogicalID: UUID?
    var offset: Int = 0
    var secondaryOffset: Int = 0
    var targetEpochID: UUID?
    var payload: Data?

    init(
        observedWinningEpochID: UUID?,
        phase: Int = 0,
        lastLogicalID: UUID? = nil,
        targetLogicalID: UUID? = nil,
        offset: Int = 0,
        secondaryOffset: Int = 0,
        targetEpochID: UUID? = nil,
        payload: Data? = nil
    ) {
        self.observedWinningEpochID = observedWinningEpochID
        self.phase = phase
        self.lastLogicalID = lastLogicalID
        self.targetLogicalID = targetLogicalID
        self.offset = max(0, offset)
        self.secondaryOffset = max(0, secondaryOffset)
        self.targetEpochID = targetEpochID
        self.payload = payload
    }
}

struct SyncMaintenanceSliceLimits: Codable, Equatable, Sendable {
    static let production = Self(
        maximumRowsPerFetch: 256,
        maximumRowsPerSlice: 1_024,
        maximumSavesPerSlice: 1
    )

    let maximumRowsPerFetch: Int
    let maximumRowsPerSlice: Int
    let maximumSavesPerSlice: Int

    init(
        maximumRowsPerFetch: Int,
        maximumRowsPerSlice: Int,
        maximumSavesPerSlice: Int
    ) {
        precondition(maximumRowsPerFetch > 0)
        precondition(maximumRowsPerSlice >= maximumRowsPerFetch)
        precondition(maximumSavesPerSlice == 1)
        self.maximumRowsPerFetch = maximumRowsPerFetch
        self.maximumRowsPerSlice = maximumRowsPerSlice
        self.maximumSavesPerSlice = maximumSavesPerSlice
    }
}

struct SyncMaintenanceFetchAudit: Codable, Equatable, Sendable {
    private(set) var rowsReturnedByFetch: [Int] = []
    private(set) var countQueryCount = 0
    private(set) var saveCount = 0

    var maximumRowsReturnedByAnyFetch: Int {
        rowsReturnedByFetch.max() ?? 0
    }

    var totalRowsAccessed: Int {
        NonnegativeIntPolicy.sum(rowsReturnedByFetch)
    }

    mutating func recordFetch(
        rows: Int,
        requestedLimit: Int,
        limits: SyncMaintenanceSliceLimits
    ) throws {
        guard requestedLimit <= limits.maximumRowsPerFetch,
              rows <= requestedLimit else {
            throw SyncMaintenanceError.fetchBudgetExceeded
        }
        rowsReturnedByFetch.append(rows)
        guard totalRowsAccessed <= limits.maximumRowsPerSlice else {
            throw SyncMaintenanceError.sliceBudgetExceeded
        }
    }

    mutating func recordCountQuery() {
        countQueryCount = NonnegativeIntPolicy.next(after: countQueryCount)
    }

    mutating func recordSave(limits: SyncMaintenanceSliceLimits) throws {
        saveCount = NonnegativeIntPolicy.next(after: saveCount)
        guard saveCount <= limits.maximumSavesPerSlice else {
            throw SyncMaintenanceError.saveBudgetExceeded
        }
    }
}

struct SyncMaintenanceSliceRequest: Codable, Equatable, Sendable {
    let kind: SyncMaintenanceKind
    let generation: UInt64
    let cursor: SyncMaintenanceCursor?
    let limits: SyncMaintenanceSliceLimits
    /// Internal tests can exercise the retained rare-ledger repair code with a
    /// custom schema. Production requests always inherit the disabled release
    /// policy and therefore never query models absent from the shipping schema.
    let includesRareRewardLedgerMaintenance: Bool

    init(
        kind: SyncMaintenanceKind,
        generation: UInt64,
        cursor: SyncMaintenanceCursor?,
        limits: SyncMaintenanceSliceLimits,
        includesRareRewardLedgerMaintenance: Bool = RareRewardReleasePolicy.isEnabled
    ) {
        self.kind = kind
        self.generation = generation
        self.cursor = cursor
        self.limits = limits
        self.includesRareRewardLedgerMaintenance = RareRewardReleasePolicy
            .permitsInternalTestOverride(includesRareRewardLedgerMaintenance)
    }
}

enum SyncMaintenanceDisposition: String, Codable, Equatable, Sendable {
    case completed
    case moreWork
    case retry
}

enum SyncMaintenanceMainActorEffect: String, Codable, Hashable, Sendable {
    case refreshActivityProjection
    case reevaluateLocalFocus
}

struct SyncMaintenanceSliceResult: Codable, Equatable, Sendable {
    let kind: SyncMaintenanceKind
    let generation: UInt64
    let disposition: SyncMaintenanceDisposition
    let nextCursor: SyncMaintenanceCursor?
    let audit: SyncMaintenanceFetchAudit
    let mainActorEffects: Set<SyncMaintenanceMainActorEffect>
    let followupKinds: Set<SyncMaintenanceKind>
    let failureCategory: String?

    static func completed(
        request: SyncMaintenanceSliceRequest,
        audit: SyncMaintenanceFetchAudit,
        effects: Set<SyncMaintenanceMainActorEffect> = [],
        followups: Set<SyncMaintenanceKind> = []
    ) -> Self {
        Self(
            kind: request.kind,
            generation: request.generation,
            disposition: .completed,
            nextCursor: nil,
            audit: audit,
            mainActorEffects: effects,
            followupKinds: followups,
            failureCategory: nil
        )
    }

    static func moreWork(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor,
        audit: SyncMaintenanceFetchAudit,
        effects: Set<SyncMaintenanceMainActorEffect> = [],
        followups: Set<SyncMaintenanceKind> = []
    ) -> Self {
        Self(
            kind: request.kind,
            generation: request.generation,
            disposition: .moreWork,
            nextCursor: cursor,
            audit: audit,
            mainActorEffects: effects,
            followupKinds: followups,
            failureCategory: nil
        )
    }

    static func retry(
        request: SyncMaintenanceSliceRequest,
        cursor: SyncMaintenanceCursor?,
        audit: SyncMaintenanceFetchAudit,
        category: String
    ) -> Self {
        Self(
            kind: request.kind,
            generation: request.generation,
            disposition: .retry,
            nextCursor: cursor,
            audit: audit,
            mainActorEffects: [],
            followupKinds: [],
            failureCategory: category
        )
    }
}

enum SyncMaintenanceError: Error, Equatable {
    case fetchBudgetExceeded
    case sliceBudgetExceeded
    case saveBudgetExceeded
    case invalidCursorPayload
}

struct SyncMaintenanceRetryState: Codable, Equatable, Sendable {
    let attempt: Int
    let notBefore: Date
    let lastFailureCategory: String

    init(
        attempt: Int,
        notBefore: Date,
        lastFailureCategory: String
    ) {
        self.attempt = min(max(1, attempt), 16)
        self.notBefore = notBefore
        self.lastFailureCategory = lastFailureCategory
    }
}

/// Entirely local state. Persisting this in SwiftData would allow one device's
/// unfinished cursor to overwrite another device's progress through CloudKit.
struct SyncMaintenanceCheckpoint: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1
    static let currentMaintenanceSchemaVersion = 1
    /// Every durable phase invalidated by a session import. Home's rootless
    /// recovery hint must preserve any one of these phases across relaunches;
    /// re-enqueueing `.sessions` would otherwise erase the active cursor and
    /// retry deadline for a backed-off downstream phase.
    static let sessionRepairPipelineKinds =
        SyncMaintenanceKind.sessions.dependentKinds

    var formatVersion = currentFormatVersion
    var maintenanceSchemaVersion = 0
    private(set) var generations: [SyncMaintenanceKind: UInt64] = [:]
    private(set) var pendingKinds: Set<SyncMaintenanceKind> = []
    private(set) var cursors: [SyncMaintenanceKind: SyncMaintenanceCursor] = [:]
    private(set) var retryAttempt = 0
    private(set) var retryNotBefore: Date?
    private(set) var lastFailureCategory: String?
    /// Optional solely so checkpoints written before per-kind retries existed
    /// still decode. The first mutation materializes the legacy global retry
    /// against the highest-priority pending kind.
    private(set) var retryStates: [SyncMaintenanceKind: SyncMaintenanceRetryState]? = [:]
    private(set) var verificationInProgress = false
    var lastFullyRepairedHistoryToken: Data?
    var historyUpperBoundToken: Data?
    /// Optional for backward-compatible decoding of checkpoints written before
    /// Home's durable repair provenance existed. `true` means a Home-triggered
    /// session pipeline is already in flight, even if earlier phases finished.
    private(set) var homeSessionRepairPipelineIsActive: Bool? = false

    static let priority: [SyncMaintenanceKind] = [
        .staleEpochCompaction,
        .preferences,
        .sessions,
        .focusFairness,
        .gacha,
        .achievements,
        .subjects,
        .strata,
        .aggregates,
        .bedrock,
        .verificationSweep
    ]

    var hasPendingWork: Bool {
        !pendingKinds.isEmpty
    }

    var isFullyVerifiedAtCurrentSchema: Bool {
        maintenanceSchemaVersion == Self.currentMaintenanceSchemaVersion
            && pendingKinds.isEmpty
            && !verificationInProgress
    }

    func generation(for kind: SyncMaintenanceKind) -> UInt64? {
        generations[kind]
    }

    func isPending(_ kind: SyncMaintenanceKind) -> Bool {
        pendingKinds.contains(kind)
    }

    /// Home's projection hint repairs sessions and every dependent projection.
    /// Merge only missing phases so an unrelated pending phase cannot suppress
    /// the repair, while an in-flight phase keeps its durable generation,
    /// keyset cursor, and retry deadline across relaunches.
    /// Fresh observed imports still use `enqueue` directly because they really
    /// do invalidate the current traversal.
    @discardableResult
    mutating func mergeSessionRepairPipeline() -> Bool {
        if homeSessionRepairPipelineIsActive == true,
           !pendingKinds.isDisjoint(with: Self.sessionRepairPipelineKinds) {
            return false
        }
        let missingKinds = Self.sessionRepairPipelineKinds.subtracting(
            pendingKinds
        )

        materializeLegacyRetryStateIfNeeded()
        homeSessionRepairPipelineIsActive = true
        for kind in missingKinds {
            let current = generations[kind] ?? 0
            generations[kind] = current == .max ? .max : current + 1
            pendingKinds.insert(kind)
            cursors.removeValue(forKey: kind)
            retryStates?.removeValue(forKey: kind)
        }
        refreshLegacyRetrySummary()
        return true
    }

    mutating func enqueue(_ kind: SyncMaintenanceKind) {
        materializeLegacyRetryStateIfNeeded()
        for expandedKind in kind.dependentKinds {
            let current = generations[expandedKind] ?? 0
            generations[expandedKind] = current == .max ? .max : current + 1
            pendingKinds.insert(expandedKind)
            // A newly observed import can sort before the current keyset.
            // Restarting only the affected kind is required for completeness.
            cursors.removeValue(forKey: expandedKind)
            retryStates?.removeValue(forKey: expandedKind)
        }
        refreshLegacyRetrySummary()
    }

    mutating func enqueueResetDependentWork() {
        for kind in SyncMaintenanceKind.allCases where kind != .verificationSweep {
            enqueue(kind)
        }
    }

    func nextRequest(
        limits: SyncMaintenanceSliceLimits = .production,
        now: Date = .now
    ) -> SyncMaintenanceSliceRequest? {
        let hasPendingNonVerificationWork = pendingKinds.contains {
            $0 != .verificationSweep
        }
        guard let kind = Self.priority.first(where: {
            guard pendingKinds.contains($0) else { return false }
            // Verification is a barrier over one fully drained maintenance
            // generation. Running it while another kind is merely in backoff
            // can enqueue follow-ups that erase that kind's retry/cursor and
            // repeatedly restart dense stores from the beginning.
            if $0 == .verificationSweep, hasPendingNonVerificationWork {
                return false
            }
            return (retryState(for: $0)?.notBefore ?? .distantPast) <= now
        }),
              let generation = generations[kind] else { return nil }
        return SyncMaintenanceSliceRequest(
            kind: kind,
            generation: generation,
            cursor: cursors[kind],
            limits: limits
        )
    }

    /// Returns false when a newer generation arrived while the slice was in
    /// flight. In that case its success must not clear the new work.
    @discardableResult
    mutating func apply(
        _ result: SyncMaintenanceSliceResult,
        now: Date = .now
    ) -> Bool {
        guard pendingKinds.contains(result.kind),
              generations[result.kind] == result.generation else {
            return false
        }
        materializeLegacyRetryStateIfNeeded()

        switch result.disposition {
        case .completed:
            pendingKinds.remove(result.kind)
            cursors.removeValue(forKey: result.kind)
            retryStates?.removeValue(forKey: result.kind)
            if result.kind == .verificationSweep {
                verificationInProgress = true
            }
        case .moreWork:
            guard let nextCursor = result.nextCursor else { return false }
            cursors[result.kind] = nextCursor
            retryStates?.removeValue(forKey: result.kind)
        case .retry:
            if let nextCursor = result.nextCursor {
                cursors[result.kind] = nextCursor
            }
            let attempt = NonnegativeIntPolicy.next(
                after: retryStates?[result.kind]?.attempt,
                minimum: 1,
                maximum: 16
            )
            let exponent = min(attempt - 1, 8)
            let delay = min(pow(2.0, Double(exponent)), 300)
            retryStates?[result.kind] = SyncMaintenanceRetryState(
                attempt: attempt,
                notBefore: now.addingTimeInterval(delay),
                lastFailureCategory: result.failureCategory ?? "unknown"
            )
        }

        for followup in result.followupKinds {
            enqueue(followup)
        }
        if homeSessionRepairPipelineIsActive == true,
           pendingKinds.isDisjoint(with: Self.sessionRepairPipelineKinds) {
            homeSessionRepairPipelineIsActive = false
        }
        refreshLegacyRetrySummary()
        if verificationInProgress && pendingKinds.isEmpty {
            maintenanceSchemaVersion = Self.currentMaintenanceSchemaVersion
            verificationInProgress = false
        }
        return true
    }

    mutating func recordFailure(
        for request: SyncMaintenanceSliceRequest,
        category: String,
        now: Date = .now
    ) {
        guard generations[request.kind] == request.generation else { return }
        let retry = SyncMaintenanceSliceResult.retry(
            request: request,
            cursor: request.cursor,
            audit: SyncMaintenanceFetchAudit(),
            category: category
        )
        _ = apply(retry, now: now)
    }

    func retryState(
        for kind: SyncMaintenanceKind
    ) -> SyncMaintenanceRetryState? {
        if let retryStates {
            return retryStates[kind]
        }
        guard kind == Self.priority.first(where: pendingKinds.contains),
              retryAttempt > 0 || retryNotBefore != nil
                || lastFailureCategory != nil
        else { return nil }
        return SyncMaintenanceRetryState(
            attempt: max(1, retryAttempt),
            notBefore: retryNotBefore ?? .distantPast,
            lastFailureCategory: lastFailureCategory ?? "unknown"
        )
    }

    private mutating func materializeLegacyRetryStateIfNeeded() {
        guard retryStates == nil else { return }
        var materialized: [
            SyncMaintenanceKind: SyncMaintenanceRetryState
        ] = [:]
        if let kind = Self.priority.first(where: pendingKinds.contains),
           retryAttempt > 0 || retryNotBefore != nil
            || lastFailureCategory != nil {
            materialized[kind] = SyncMaintenanceRetryState(
                attempt: max(1, retryAttempt),
                notBefore: retryNotBefore ?? .distantPast,
                lastFailureCategory: lastFailureCategory ?? "unknown"
            )
        }
        retryStates = materialized
        refreshLegacyRetrySummary()
    }

    /// Keep the original scalar fields as a downgrade-friendly summary and as
    /// the foreground drain's earliest wake-up deadline.
    private mutating func refreshLegacyRetrySummary() {
        let pendingStates = Self.priority.compactMap { kind -> (
            Int,
            SyncMaintenanceRetryState
        )? in
            guard pendingKinds.contains(kind),
                  let state = retryStates?[kind] else { return nil }
            return (Self.priority.firstIndex(of: kind) ?? .max, state)
        }
        let summary = pendingStates.min { lhs, rhs in
            if lhs.1.notBefore != rhs.1.notBefore {
                return lhs.1.notBefore < rhs.1.notBefore
            }
            return lhs.0 < rhs.0
        }?.1
        retryAttempt = summary?.attempt ?? 0
        retryNotBefore = summary?.notBefore
        lastFailureCategory = summary?.lastFailureCategory
    }
}

@MainActor
final class SyncMaintenanceCheckpointStore {
    static let defaultKey = "sync-maintenance.checkpoint.v1"

    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        key: String? = nil
    ) {
        self.defaults = defaults
        self.key = key ?? AccountScopedLocalState.defaultsKey(
            base: Self.defaultKey,
            defaults: defaults
        )
    }

    func load() -> SyncMaintenanceCheckpoint {
        guard let data = defaults.data(forKey: key),
              let decoded = try? decoder.decode(
                SyncMaintenanceCheckpoint.self,
                from: data
              ),
              decoded.formatVersion == SyncMaintenanceCheckpoint.currentFormatVersion
        else { return SyncMaintenanceCheckpoint() }
        return decoded
    }

    func save(_ checkpoint: SyncMaintenanceCheckpoint) {
        guard let data = try? encoder.encode(checkpoint) else { return }
        defaults.set(data, forKey: key)
    }

    func remove() {
        defaults.removeObject(forKey: key)
    }
}

/// Main-actor arbiter. Re-entrant calls while awaiting the ModelActor observe
/// `isWorkerInFlight` and therefore cannot create a second concurrent slice.
@MainActor
final class SyncMaintenanceCoordinator {
    typealias Runner = @Sendable (
        SyncMaintenanceSliceRequest,
        ModelContainer
    ) async throws -> SyncMaintenanceSliceResult

    private let store: SyncMaintenanceCheckpointStore
    private let runner: Runner
    private(set) var checkpoint: SyncMaintenanceCheckpoint
    private(set) var isWorkerInFlight = false

    init(
        store: SyncMaintenanceCheckpointStore? = nil,
        runner: @escaping Runner = { request, container in
            let worker = SyncMaintenanceSliceWorker(modelContainer: container)
            return try worker.run(request)
        }
    ) {
        let resolvedStore = store ?? SyncMaintenanceCheckpointStore()
        self.store = resolvedStore
        self.runner = runner
        checkpoint = resolvedStore.load()
    }

    func enqueue(_ kind: SyncMaintenanceKind) {
        checkpoint.enqueue(kind)
        store.save(checkpoint)
    }

    @discardableResult
    func mergeSessionRepairPipeline() -> Bool {
        guard checkpoint.mergeSessionRepairPipeline() else {
            return false
        }
        store.save(checkpoint)
        return true
    }

    func enqueueResetDependentWork() {
        checkpoint.enqueueResetDependentWork()
        store.save(checkpoint)
    }

    @discardableResult
    func runNextSlice(
        modelContainer: ModelContainer,
        isForeground: Bool,
        limits: SyncMaintenanceSliceLimits = .production,
        now: Date = .now,
        applyEffect: (SyncMaintenanceMainActorEffect) -> Void = { _ in }
    ) async -> SyncMaintenanceSliceResult? {
        guard isForeground, !isWorkerInFlight,
              let request = checkpoint.nextRequest(limits: limits, now: now)
        else { return nil }

        // The enqueue/generation state is durable before any model mutation.
        store.save(checkpoint)
        isWorkerInFlight = true
        defer { isWorkerInFlight = false }

        do {
            let result = try await runner(request, modelContainer)
            let applied = checkpoint.apply(result, now: now)
            store.save(checkpoint)
            if applied {
                for effect in result.mainActorEffects { applyEffect(effect) }
            }
            return result
        } catch is CancellationError {
            // The actor either saved an idempotent atomic unit or rolled back.
            // Keeping the pre-slice cursor makes either outcome safe to replay.
            store.save(checkpoint)
            return nil
        } catch {
            checkpoint.recordFailure(
                for: request,
                category: String(reflecting: type(of: error)),
                now: now
            )
            store.save(checkpoint)
            return nil
        }
    }
}
