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

    static func sessionCountDescriptor(
        currentEpochID: UUID?
    ) -> FetchDescriptor<StudySession> {
        if let currentEpochID {
            let epochID = currentEpochID
            return FetchDescriptor<StudySession>(predicate: #Predicate { session in
                session.dataEpochID == epochID
            })
        }
        return FetchDescriptor<StudySession>(predicate: #Predicate { session in
            session.dataEpochID == nil
        })
    }

    /// Loads the complete finite calendar week in stable pages. The ordinary
    /// history page remains bounded to 720 rows, but a dense week must not
    /// understate the value-bearing measured mass merely because older rows
    /// fell outside that presentation page.
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
        let start = interval.start
        let end = interval.end
        var offset = 0
        var result: [StudySession] = []

        while true {
            var descriptor: FetchDescriptor<StudySession>
            if let currentEpochID {
                let epochID = currentEpochID
                descriptor = FetchDescriptor<StudySession>(
                    predicate: #Predicate { session in
                        session.dataEpochID == epochID
                            && session.endAt >= start
                            && session.endAt < end
                    },
                    sortBy: [
                        SortDescriptor(\StudySession.endAt, order: .reverse),
                        SortDescriptor(\StudySession.id, order: .reverse)
                    ]
                )
            } else {
                descriptor = FetchDescriptor<StudySession>(
                    predicate: #Predicate { session in
                        session.dataEpochID == nil
                            && session.endAt >= start
                            && session.endAt < end
                    },
                    sortBy: [
                        SortDescriptor(\StudySession.endAt, order: .reverse),
                        SortDescriptor(\StudySession.id, order: .reverse)
                    ]
                )
            }
            descriptor.fetchLimit = weeklySessionPageLimit
            descriptor.fetchOffset = offset
            let page = try context.fetch(descriptor)
            result.append(contentsOf: page)
            guard page.count == weeklySessionPageLimit,
                  offset <= Int.max - page.count
            else { break }
            offset += page.count
        }
        return result
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
    let initialClusterID: UUID?

    @Environment(\.modelContext) private var modelContext
    @State private var page: Page?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let page {
                AccumulationOverviewView(
                    records: page.records,
                    clusters: page.clusters,
                    milestones: page.milestones,
                    lifetimeGrams: lifetimeGrams,
                    lifetimePebbleCount: lifetimePebbleCount,
                    pageScope: page.scope,
                    lifetimeIsLowerBound: lifetimeIsLowerBound,
                    initialClusterID: initialClusterID
                )
            } else if let loadError {
                ContentUnavailableView(
                    "積み上がりを読み込めませんでした",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ProgressView("積み上がりを読み込み中")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NightBackground())
            }
        }
        .task { loadPage() }
    }

    @MainActor
    private func loadPage() {
        do {
            let currentEpochID = ActivityResetPolicy.currentEpochID(
                from: resetMarkers
            )
            let recentSessions = try modelContext.fetch(
                AccumulationOverviewLoaderPolicy.sessionPageDescriptor(
                    currentEpochID: currentEpochID
                )
            )
            let weeklySessions = try AccumulationOverviewLoaderPolicy.weeklySessions(
                context: modelContext,
                currentEpochID: currentEpochID
            )
            let sessions = Dictionary(
                grouping: recentSessions + weeklySessions,
                by: \.id
            ).values.compactMap { duplicates in
                duplicates.max { lhs, rhs in
                    if lhs.endAt == rhs.endAt {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.endAt < rhs.endAt
                }
            }
            .sorted { lhs, rhs in
                if lhs.endAt == rhs.endAt {
                    return lhs.id.uuidString > rhs.id.uuidString
                }
                return lhs.endAt > rhs.endAt
            }
            let persistedSessionCount = try modelContext.fetchCount(
                AccumulationOverviewLoaderPolicy.sessionCountDescriptor(
                    currentEpochID: currentEpochID
                )
            )

            let aggregates = try modelContext.fetch(
                AccumulationOverviewLoaderPolicy.aggregatePageDescriptor(
                    currentEpochID: currentEpochID
                )
            )

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
                        isBaked: $0.isBaked
                    )
                },
                clusters: AggregatePebblePolicy.disjointRootSummaries(from: aggregates).map {
                    AccumulationClusterSummary(
                        id: $0.id,
                        level: $0.level,
                        pebbleCount: $0.pebbleCount,
                        grams: $0.grams,
                        periodStart: $0.periodStart,
                        periodEnd: $0.periodEnd,
                        colorMix: $0.colorMix,
                        subjectMix: $0.subjectMix,
                        childCount: $0.childAggregateCount,
                        // Descendant membership is intentionally not flattened
                        // for the overview page. The record page is bounded and
                        // current loose rows already carry `isBaked == false`.
                        sessionIDs: [],
                        measuredPebbleCount: $0.measuredPebbleCount,
                        manualPebbleCount: $0.manualPebbleCount,
                        goldPebbleCount: $0.goldPebbleCount,
                        prismPebbleCount: $0.prismPebbleCount
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
                    totalSessionCount: persistedSessionCount,
                    displayedSessionCount: sessions.count,
                    totalAchievementCount: achievements.count,
                    displayedAchievementCount: achievements.count,
                    totalAchievementCountIsLowerBound: achievementCountIsLowerBound
                )
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
    }
}
