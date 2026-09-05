import SwiftData
import SwiftUI

enum AccumulationOverviewLoaderPolicy {
    static let sessionPageLimit = 720
    static let weeklySessionPageLimit = 512
    static let achievementPageLimit = 120

    static func sessionPageDescriptor(
        currentEpochID: UUID?
    ) -> FetchDescriptor<StudySession> {
        var descriptor: FetchDescriptor<StudySession>
        if let currentEpochID {
            let epochID = currentEpochID
            descriptor = FetchDescriptor<StudySession>(
                predicate: #Predicate { session in
                    session.dataEpochID == epochID
                },
                sortBy: [SortDescriptor(\StudySession.endAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<StudySession>(
                predicate: #Predicate { session in
                    session.dataEpochID == nil
                },
                sortBy: [SortDescriptor(\StudySession.endAt, order: .reverse)]
            )
        }
        descriptor.fetchLimit = sessionPageLimit
        return descriptor
    }

    /// Loads one finite week and exact-resolves every candidate logical ID
    /// before testing week membership. The hard cap fails closed rather than
    /// silently treating a physical duplicate prefix as complete history.
    @MainActor
    static func weeklySessions(
        context: ModelContext,
        currentEpochID: UUID?,
        referenceDate: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> [StudySession] {
        guard let interval = calendar.dateInterval(
            of: .weekOfYear,
            for: referenceDate
        ) else { return [] }
        return try BoundedHistoryPolicy.resolvedSessionsInFiniteInterval(
            context: context,
            epochID: currentEpochID,
            interval: interval,
            maximumPhysicalRows: BoundedHistoryPolicy.weeklySessionRowLimit
        )
    }

    static func aggregatePageDescriptor(
        currentEpochID: UUID?
    ) -> FetchDescriptor<AggregatePebble> {
        var descriptor: FetchDescriptor<AggregatePebble>
        if let currentEpochID {
            let epochID = currentEpochID
            descriptor = FetchDescriptor<AggregatePebble>(
                predicate: #Predicate { aggregate in
                    aggregate.parentAggregateID == nil
                        && aggregate.dataEpochID == epochID
                },
                sortBy: [SortDescriptor(\AggregatePebble.createdAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<AggregatePebble>(
                predicate: #Predicate { aggregate in
                    aggregate.parentAggregateID == nil
                        && aggregate.dataEpochID == nil
                },
                sortBy: [SortDescriptor(\AggregatePebble.createdAt, order: .reverse)]
            )
        }
        descriptor.fetchLimit = Constants.Jar.maximumVisibleAggregateRoots
        return descriptor
    }

    /// Bounded active candidates. `AccumulationOverviewLoader` performs a
    /// tombstone-inclusive exact-ID resolution before building summaries.
    static func achievementCandidatePageDescriptor(
        currentEpochID: UUID?
    ) -> FetchDescriptor<AchievementStone> {
        var descriptor: FetchDescriptor<AchievementStone>
        if let currentEpochID {
            let epochID = currentEpochID
            descriptor = FetchDescriptor<AchievementStone>(
                predicate: #Predicate { stone in
                    stone.dataEpochID == epochID && stone.deletedAt == nil
                },
                sortBy: [SortDescriptor(\AchievementStone.achievedAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<AchievementStone>(
                predicate: #Predicate { stone in
                    stone.dataEpochID == nil && stone.deletedAt == nil
                },
                sortBy: [SortDescriptor(\AchievementStone.achievedAt, order: .reverse)]
            )
        }
        descriptor.fetchLimit = achievementPageLimit
        return descriptor
    }

    static func achievementCountDescriptor(
        currentEpochID: UUID?
    ) -> FetchDescriptor<AchievementStone> {
        if let currentEpochID {
            let epochID = currentEpochID
            return FetchDescriptor<AchievementStone>(predicate: #Predicate { stone in
                stone.dataEpochID == epochID && stone.deletedAt == nil
            })
        }
        return FetchDescriptor<AchievementStone>(predicate: #Predicate { stone in
            stone.dataEpochID == nil && stone.deletedAt == nil
        })
    }
}

/// Explicit-navigation loader for the overview. Home never owns these history
/// objects; dismissing the sheet releases this bounded page.
struct AccumulationOverviewLoader: View {
    let resetMarkers: [ActivityResetSnapshot]
    let lifetimeGrams: Int
    let lifetimePebbleCount: Int
    let lifetimeIsLowerBound: Bool
    let projectionPresentation: AggregateProjectionPresentationContext
    let initialClusterID: UUID?

    @Environment(\.modelContext) private var modelContext
    @State private var page: Page?
    @State private var loadError: String?

    private var lifetimeIsCloudUnverified: Bool {
        projectionPresentation.isCloudVerificationPending
    }

    var body: some View {
        Group {
            if let page,
               projectionPresentation.acceptsVerifiedAggregateCache(
                   page.projectionCacheStamp
               ) {
                AccumulationOverviewView(
                    records: page.records,
                    // The whole page is lease-gated above. In particular,
                    // record aggregate-membership flags and PageScope totals
                    // are just as projection-dependent as visible clusters.
                    clusters: page.clusters,
                    milestones: page.milestones,
                    lifetimeGrams: lifetimeGrams,
                    lifetimePebbleCount: lifetimePebbleCount,
                    pageScope: page.scope,
                    lifetimeIsLowerBound: lifetimeIsLowerBound,
                    lifetimeIsCloudUnverified: lifetimeIsCloudUnverified,
                    initialClusterID: initialClusterID
                )
            } else if let loadError {
                ContentUnavailableView(
                    "積み上がりを読み込めませんでした",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if lifetimeIsCloudUnverified {
                ContentUnavailableView(
                    "iCloudを再集計中",
                    systemImage: "icloud.and.arrow.down",
                    description: Text(
                        "更新前の履歴ページは再利用せず、確認後に読み込み直します。"
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NightBackground())
            } else {
                ProgressView("積み上がりを読み込み中")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NightBackground())
            }
        }
        .task(id: projectionPresentation) { loadPage() }
    }

    @MainActor
    private func loadPage() {
        loadError = nil
        let projectionCacheStamp = projectionPresentation.verifiedCacheStamp
        do {
            let currentEpochID = ActivityResetPolicy.currentEpochID(
                from: resetMarkers
            )
            let recentPage = try BoundedHistoryPolicy.resolvedSessionPage(
                context: modelContext,
                epochID: currentEpochID,
                order: .reverse,
                logicalLimit: AccumulationOverviewLoaderPolicy.sessionPageLimit
            )
            let weeklySessions = try AccumulationOverviewLoaderPolicy.weeklySessions(
                context: modelContext,
                currentEpochID: currentEpochID
            )
            let sessions = StudySessionSyncPolicy.canonicalSessions(
                from: recentPage.sessions + weeklySessions
            )
            .sorted { lhs, rhs in
                if lhs.endAt == rhs.endAt {
                    return lhs.id.uuidString > rhs.id.uuidString
                }
                return lhs.endAt > rhs.endAt
            }
            let aggregates: [AggregatePebble]
            if projectionCacheStamp == nil {
                // A locally valid projection can become stale after another
                // device edits a source row. Suppress every aggregate root
                // until the current verification generation has drained.
                aggregates = []
            } else {
                aggregates = try modelContext.fetch(
                    AccumulationOverviewLoaderPolicy.aggregatePageDescriptor(
                        currentEpochID: currentEpochID
                    )
                )
            }
            let acceptedAggregateIDs = try HomeProjectionPolicy
                .acceptedRootSummaryIDs(
                    roots: aggregates,
                    context: modelContext,
                    resetMarkers: resetMarkers
                )
            let displayedAggregates = AggregatePebblePolicy.disjointRootSummaries(
                from: aggregates.filter { acceptedAggregateIDs.contains($0.id) }
            )
            let localMembership = try HomeProjectionPolicy.localMembershipProjection(
                for: sessions,
                representedAggregateRoots: displayedAggregates,
                context: modelContext,
                resetMarkers: resetMarkers
            )
            let safeDisplayedAggregates = displayedAggregates.filter {
                !localMembership.conflictedRootIDs.contains($0.id)
            }

            let achievementCandidates = try modelContext.fetch(
                AccumulationOverviewLoaderPolicy.achievementCandidatePageDescriptor(
                    currentEpochID: currentEpochID
                )
            )
            let rawActiveAchievementCount = try modelContext.fetchCount(
                AccumulationOverviewLoaderPolicy.achievementCountDescriptor(
                    currentEpochID: currentEpochID
                )
            )
            let achievements = try AchievementStonePolicy.resolvedVisibleCandidates(
                from: achievementCandidates,
                context: modelContext
            )
            let achievementCountIsLowerBound = rawActiveAchievementCount
                > achievementCandidates.count

            page = Page(
                records: sessions.map {
                    AccumulationRecord(
                        id: $0.id,
                        date: $0.endAt,
                        subjectName: $0.displaySubjectName,
                        colorHex: $0.displaySubjectColorHex,
                        grams: $0.grams,
                        isMeasured: $0.source == .timer,
                        isRepresentedByLocalAggregate: localMembership
                            .representedSessionIDs.contains($0.id)
                    )
                },
                clusters: safeDisplayedAggregates.map {
                    AccumulationClusterSummary(
                        aggregate: $0,
                        // Descendant membership is intentionally not flattened
                        // into every root. The separate bounded local leaf
                        // lookup above owns record exclusion.
                        sessionIDs: []
                    )
                },
                milestones: achievements.map {
                    AccumulationMilestoneSummary(
                        id: $0.id,
                        date: $0.achievedAt,
                        title: $0.displayTitle,
                        subjectName: $0.displaySubjectName,
                        colorHex: $0.kind.gemBaseHex,
                        mark: $0.kind.shortMark
                    )
                },
                scope: AccumulationOverviewPageScope(
                    // Home's lifetime projection counts logical session IDs.
                    // A raw SwiftData fetchCount would expose transient
                    // CloudKit replica multiplicity as user history.
                    totalSessionCount: lifetimePebbleCount,
                    displayedSessionCount: sessions.count,
                    totalSessionCountIsLowerBound: lifetimeIsLowerBound,
                    totalSessionCountIsCloudUnverified:
                        lifetimeIsCloudUnverified,
                    totalAchievementCount: achievements.count,
                    displayedAchievementCount: achievements.count,
                    totalAchievementCountIsLowerBound: achievementCountIsLowerBound
                ),
                projectionCacheStamp: projectionCacheStamp
            )
        } catch {
            loadError = error.localizedDescription
        }
    }

    private struct Page {
        let records: [AccumulationRecord]
        let clusters: [AccumulationClusterSummary]
        let milestones: [AccumulationMilestoneSummary]
        let scope: AccumulationOverviewPageScope
        let projectionCacheStamp: AggregateProjectionCacheStamp?
    }
}
