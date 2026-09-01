#if DEBUG
import Darwin
import Foundation
import SwiftData

/// An explicitly opted-in, disposable SwiftData stress harness.
///
/// Unlike `FortyYearDebugScenario`, this writes every fixture row to a real
/// SQLite-backed SwiftData store. The store lives in a unique temporary
/// directory, never uses CloudKit, and is removed when the run finishes.
enum FortyYearPersistenceHarness {
    static let optInEnvironmentKey = "TSUMIBEN_RUN_40_YEAR_PERSISTENCE"

    enum Expected {
        static let subjectCount = 5
        static let sessionCount = FortyYearDebugScenario.Expected.completionCount
        static let bakedSessionCount = sessionCount
        static let looseSessionCount = 0
        static let aggregateCount = FortyYearDebugScenario.Expected.aggregateCreationCount
        static let rootAggregateCount = 18
        static let achievementCount = FortyYearDebugScenario.Expected.achievementCount
        static let visibleAchievementCount = FortyYearDebugScenario.Expected
            .visibleAchievementCount
        static let achievementCountsByKind = Dictionary(
            uniqueKeysWithValues: AchievementKind.allCases.map { ($0, 40) }
        )
        static let projectedStudyDescriptorCount = FortyYearDebugScenario.Expected.studyBodyCount
        static let projectedDescriptorCount = projectedStudyDescriptorCount
            + visibleAchievementCount
        static let representedPebbleCount = sessionCount
        static let grams = FortyYearDebugScenario.Expected.grams
        /// Five subjects + 350,640 sessions + 38,958 aggregate rows.
        static let studyHierarchyRowCount = subjectCount + sessionCount + aggregateCount
        static let totalPersistedRows = studyHierarchyRowCount + achievementCount
        /// Compact lineage stores membership once at level 1. Higher levels
        /// point to ten children instead of repeating every descendant UUID.
        static let sessionIDReferenceCount = bakedSessionCount
        static let maximumSessionIDsPerAggregate = Constants.Jar.aggregateFanIn
        static let childAggregateIDReferenceCount = aggregateCount - rootAggregateCount
        static let maximumChildIDsPerAggregate = Constants.Jar.aggregateFanIn
    }

    /// Generous regression gates derived from the 2026-08-31 simulator baseline
    /// (48.27s insert, 12.07s full fetch, 0.117s cold projection, 105MB store,
    /// 769MB full-fetch peak). They allow slower shared CI hosts while still
    /// failing a materially unbounded projection or accidental store explosion.
    enum PerformanceBudget {
        static let maximumInsertionSeconds: TimeInterval = 300
        static let maximumFullFetchSeconds: TimeInterval = 60
        static let maximumColdProjectionSeconds: TimeInterval = 2
        static let maximumStoreBytes: UInt64 = 256 * 1_024 * 1_024
        static let maximumInsertionPeakResidentBytes: UInt64 = 1_536 * 1_024 * 1_024
        static let maximumFullFetchPeakResidentBytes: UInt64 = 1_536 * 1_024 * 1_024
        static let maximumColdProjectionPeakResidentBytes: UInt64 = 384 * 1_024 * 1_024

        static let rationale = "2026-08-31実測値に、共有CIの速度差と計測揺れを含む余裕を持たせた回帰上限です。"

        static var summary: String {
            "保存≤300秒、全件fetch≤60秒、cold projection≤2秒、store≤256MiB、peak≤1.5GiB（cold≤384MiB）"
        }

        static func failureReasons(
            storeBytes: UInt64,
            insertion: StageMetrics,
            fullFetch: StageMetrics,
            coldProjection: StageMetrics
        ) -> [String] {
            var reasons: [String] = []
            appendDurationFailure(
                name: "保存",
                actual: insertion.elapsedSeconds,
                maximum: maximumInsertionSeconds,
                to: &reasons
            )
            appendDurationFailure(
                name: "全件fetch",
                actual: fullFetch.elapsedSeconds,
                maximum: maximumFullFetchSeconds,
                to: &reasons
            )
            appendDurationFailure(
                name: "cold projection",
                actual: coldProjection.elapsedSeconds,
                maximum: maximumColdProjectionSeconds,
                to: &reasons
            )
            appendByteFailure(
                name: "store容量",
                actual: storeBytes,
                maximum: maximumStoreBytes,
                to: &reasons
            )
            appendByteFailure(
                name: "保存peak",
                actual: insertion.peakResidentBytes,
                maximum: maximumInsertionPeakResidentBytes,
                to: &reasons
            )
            appendByteFailure(
                name: "全件fetch peak",
                actual: fullFetch.peakResidentBytes,
                maximum: maximumFullFetchPeakResidentBytes,
                to: &reasons
            )
            appendByteFailure(
                name: "cold projection peak",
                actual: coldProjection.peakResidentBytes,
                maximum: maximumColdProjectionPeakResidentBytes,
                to: &reasons
            )
            return reasons
        }

        private static func appendDurationFailure(
            name: String,
            actual: TimeInterval,
            maximum: TimeInterval,
            to reasons: inout [String]
        ) {
            guard actual.isFinite, actual >= 0, actual <= maximum else {
                reasons.append(
                    String(format: "%@ %.2f秒（上限 %.0f秒）", name, actual, maximum)
                )
                return
            }
        }

        private static func appendByteFailure(
            name: String,
            actual: UInt64,
            maximum: UInt64,
            to reasons: inout [String]
        ) {
            guard actual > 0, actual <= maximum else {
                reasons.append(
                    "\(name) \(actual)B（上限 \(maximum)B）"
                )
                return
            }
        }
    }

    struct StageMetrics: Equatable, Sendable {
        let elapsedSeconds: TimeInterval
        let rowCount: Int
        let residentBytesBefore: UInt64
        let residentBytesAfter: UInt64
        let peakResidentBytes: UInt64

        var residentDeltaBytes: Int64 {
            Int64(clamping: residentBytesAfter) - Int64(clamping: residentBytesBefore)
        }
    }

    struct Report: Equatable, Sendable {
        let storeBytes: UInt64
        let insertion: StageMetrics
        let fullFetch: StageMetrics
        let coldProjection: StageMetrics
        let insertedSessionCount: Int
        let insertedAggregateCount: Int
        let insertedAchievementCount: Int
        let fetchedSubjectCount: Int
        let fetchedSessionCount: Int
        let fetchedAggregateCount: Int
        let fetchedAchievementCount: Int
        let fetchedGoldSessionCount: Int
        let fetchedPrismSessionCount: Int
        let fetchedAggregatesByLevel: [Int: Int]
        let sessionIDReferenceCount: Int
        let maximumSessionIDsPerAggregate: Int
        let childAggregateIDReferenceCount: Int
        let maximumChildIDsPerAggregate: Int
        let coldSessionCount: Int
        let coldAggregateCount: Int
        let coldRootAggregateCount: Int
        let coldLooseSessionCount: Int
        let coldAchievementCount: Int
        let coldVisibleAchievementCount: Int
        let coldAchievementCountsByKind: [AchievementKind: Int]
        let coldGoldCount: Int
        let coldPrismCount: Int
        let projectedDescriptorCount: Int
        let projectedQueueCount: Int
        let representedPebbleCount: Int
        let representedGrams: Int
        let goldCount: Int
        let prismCount: Int

        var dataIntegrityPassed: Bool {
            storeBytes > 0
                && insertion.rowCount == Expected.totalPersistedRows
                && fullFetch.rowCount == Expected.totalPersistedRows
                && insertedSessionCount == Expected.sessionCount
                && insertedAggregateCount == Expected.aggregateCount
                && insertedAchievementCount == Expected.achievementCount
                && fetchedSubjectCount == Expected.subjectCount
                && fetchedSessionCount == Expected.sessionCount
                && fetchedAggregateCount == Expected.aggregateCount
                && fetchedAchievementCount == Expected.achievementCount
                && fetchedGoldSessionCount == FortyYearDebugScenario.Expected.goldCount
                && fetchedPrismSessionCount == FortyYearDebugScenario.Expected.prismCount
                && fetchedAggregatesByLevel == FortyYearDebugScenario.Expected.aggregateCreationsByLevel
                && sessionIDReferenceCount == Expected.sessionIDReferenceCount
                && maximumSessionIDsPerAggregate == Expected.maximumSessionIDsPerAggregate
                && childAggregateIDReferenceCount == Expected.childAggregateIDReferenceCount
                && maximumChildIDsPerAggregate == Expected.maximumChildIDsPerAggregate
                && coldSessionCount == Expected.sessionCount
                && coldAggregateCount == Expected.aggregateCount
                && coldRootAggregateCount == Expected.rootAggregateCount
                && coldLooseSessionCount == Expected.looseSessionCount
                && coldAchievementCount == Expected.achievementCount
                && coldVisibleAchievementCount == Expected.visibleAchievementCount
                && coldAchievementCountsByKind == Expected.achievementCountsByKind
                && coldGoldCount == FortyYearDebugScenario.Expected.goldCount
                && coldPrismCount == FortyYearDebugScenario.Expected.prismCount
                && projectedDescriptorCount == Expected.projectedDescriptorCount
                && projectedDescriptorCount <= Constants.Jar.maxPhysicsBodies
                && projectedQueueCount == 0
                && representedPebbleCount == Expected.representedPebbleCount
                && representedGrams == Expected.grams
                && goldCount == FortyYearDebugScenario.Expected.goldCount
                && prismCount == FortyYearDebugScenario.Expected.prismCount
        }

        var performanceFailureReasons: [String] {
            PerformanceBudget.failureReasons(
                storeBytes: storeBytes,
                insertion: insertion,
                fullFetch: fullFetch,
                coldProjection: coldProjection
            )
        }

        var failureReasons: [String] {
            (dataIntegrityPassed ? [] : ["cold reopen後の件数・質量・希少内訳・成果石が期待値と一致しません。"])
                + performanceFailureReasons
        }

        var passed: Bool {
            dataIntegrityPassed && performanceFailureReasons.isEmpty
        }
    }

    enum Stage: String, Equatable, Sendable {
        case preparing = "隔離ストアを準備"
        case insertingSessions = "350,640件を保存"
        case insertingAggregates = "まとまり階層を保存"
        case insertingAchievements = "成果石120件を保存"
        case fullFetch = "全件fetchを計測"
        case coldProjection = "cold projectionを計測"
        case finishing = "結果を検証"
    }

    struct Progress: Equatable, Sendable {
        let stage: Stage
        let completed: Int
        let total: Int

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, max(0, Double(completed) / Double(total)))
        }
    }

    struct Options: Equatable, Sendable {
        var sessionBatchSize = 2_000
        var aggregateBatchSize = 250

        static let full = Options()
    }

    static var isOptedInForCurrentProcess: Bool {
        let value = ProcessInfo.processInfo.environment[optInEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    static func run(
        options: Options = .full,
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Report {
        guard isOptedInForCurrentProcess else {
            throw HarnessError.explicitOptInRequired
        }
        guard options.sessionBatchSize > 0, options.aggregateBatchSize > 0 else {
            throw HarnessError.invalidBatchSize
        }

        let worker = Task.detached(priority: .utility) {
            try runSynchronously(options: options, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func runSynchronously(
        options: Options,
        progress: @escaping @Sendable (Progress) -> Void
    ) throws -> Report {
        progress(Progress(stage: .preparing, completed: 0, total: 1))
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Tsumiben-40Year-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("FortyYear.store")
        var insertionContainer: ModelContainer? = try makeContainer(storeURL: storeURL)
        progress(Progress(stage: .preparing, completed: 1, total: 1))

        let fixtureStart = fixtureStartDate
        let dayKeys = makeDayKeys(startingAt: fixtureStart)
        var goldPrefixes = [Int32]()
        var prismPrefixes = [Int32]()
        goldPrefixes.reserveCapacity(Expected.sessionCount + 1)
        prismPrefixes.reserveCapacity(Expected.sessionCount + 1)
        goldPrefixes.append(0)
        prismPrefixes.append(0)

        let insertionMemoryBefore = residentBytes()
        var insertionPeak = insertionMemoryBefore
        let insertionStartedAt = ContinuousClock.now
        try insertSubjects(into: insertionContainer!, createdAt: fixtureStart)

        var random = SplitMix64(seed: 0x5453_554D_4942_454E)
        var missesSinceGold = 0
        var insertedSessionCount = 0
        var goldCount = 0
        var prismCount = 0

        for batchStart in stride(
            from: 0,
            to: Expected.sessionCount,
            by: options.sessionBatchSize
        ) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + options.sessionBatchSize, Expected.sessionCount)
            try autoreleasepool {
                let context = ModelContext(insertionContainer!)
                context.autosaveEnabled = false
                for index in batchStart ..< batchEnd {
                    let reward = GachaEngine.draw(
                        source: .timer,
                        completedSeconds: Constants.Timer.twentyFiveMinutes
                            * Constants.Timer.secondsPerMinute,
                        sinceLastGold: missesSinceGold,
                        unitRoll: random.nextUnitDouble()
                    )
                    missesSinceGold = reward.sinceLastGold
                    if reward.kind == .gold { goldCount += 1 }
                    if reward.kind == .prism { prismCount += 1 }
                    goldPrefixes.append(
                        goldPrefixes[goldPrefixes.count - 1]
                            + (reward.kind == .gold ? 1 : 0)
                    )
                    prismPrefixes.append(
                        prismPrefixes[prismPrefixes.count - 1]
                            + (reward.kind == .prism ? 1 : 0)
                    )

                    let dayIndex = index / FortyYearDebugScenario.Expected.focusSessionsPerDay
                    let slot = index % FortyYearDebugScenario.Expected.focusSessionsPerDay
                    let startAt = fixtureDate(
                        fixtureStart: fixtureStart,
                        dayIndex: dayIndex,
                        slot: slot
                    )
                    let subject = fixtureSubjects[index % fixtureSubjects.count]
                    context.insert(StudySession(
                        id: sessionID(index: index),
                        startAt: startAt,
                        endAt: startAt.addingTimeInterval(
                            TimeInterval(Constants.Timer.twentyFiveMinutes
                                * Constants.Timer.secondsPerMinute)
                        ),
                        seconds: Constants.Timer.twentyFiveMinutes
                            * Constants.Timer.secondsPerMinute,
                        source: .timer,
                        pebbleKind: reward.kind,
                        grams: Constants.Timer.twentyFiveMinutes
                            * Constants.Mass.gramsPerMinute,
                        deviceDayKey: dayKeys[dayIndex],
                        isBaked: index < Expected.bakedSessionCount,
                        subjectNameSnapshot: subject.name,
                        subjectColorHexSnapshot: subject.colorHex,
                        subjectIDSnapshot: subject.id
                    ))
                }
                try context.save()
            }
            insertedSessionCount = batchEnd
            insertionPeak = max(insertionPeak, residentBytes())
            progress(Progress(
                stage: .insertingSessions,
                completed: batchEnd,
                total: Expected.sessionCount
            ))
        }

        guard goldCount == FortyYearDebugScenario.Expected.goldCount,
              prismCount == FortyYearDebugScenario.Expected.prismCount
        else {
            throw HarnessError.rewardFixtureMismatch
        }

        var insertedAggregateCount = 0
        for level in 1 ... 5 {
            guard let count = FortyYearDebugScenario.Expected.aggregateCreationsByLevel[level]
            else { throw HarnessError.aggregateFixtureMismatch }
            let groupSize = decimalPower(level)
            for batchStart in stride(from: 0, to: count, by: options.aggregateBatchSize) {
                try Task.checkCancellation()
                let batchEnd = min(batchStart + options.aggregateBatchSize, count)
                try autoreleasepool {
                    let context = ModelContext(insertionContainer!)
                    context.autosaveEnabled = false
                    for aggregateIndex in batchStart ..< batchEnd {
                        let sessionStart = aggregateIndex * groupSize
                        let sessionEnd = sessionStart + groupSize
                        let sessionIDs = level == 1
                            ? (sessionStart ..< sessionEnd).map(sessionID(index:))
                            : []
                        let childIDs: [UUID]
                        if level == 1 {
                            childIDs = []
                        } else {
                            childIDs = (aggregateIndex * Constants.Jar.aggregateFanIn
                                ..< (aggregateIndex + 1) * Constants.Jar.aggregateFanIn)
                                .map { aggregateID(level: level - 1, index: $0) }
                        }
                        let parentID: UUID?
                        if let parentCount = FortyYearDebugScenario.Expected
                            .aggregateCreationsByLevel[level + 1],
                           aggregateIndex < parentCount * Constants.Jar.aggregateFanIn {
                            parentID = aggregateID(
                                level: level + 1,
                                index: aggregateIndex / Constants.Jar.aggregateFanIn
                            )
                        } else {
                            parentID = nil
                        }
                        let periodStart = fixtureDate(
                            fixtureStart: fixtureStart,
                            globalSessionIndex: sessionStart
                        )
                        let finalStart = fixtureDate(
                            fixtureStart: fixtureStart,
                            globalSessionIndex: sessionEnd - 1
                        )
                        let periodEnd = finalStart.addingTimeInterval(
                            TimeInterval(Constants.Timer.twentyFiveMinutes
                                * Constants.Timer.secondsPerMinute)
                        )
                        let subjectMix = fixtureSubjects.map {
                            AggregateSubjectFraction(
                                name: $0.name,
                                colorHex: $0.colorHex,
                                pebbleCount: groupSize / fixtureSubjects.count
                            )
                        }
                        context.insert(AggregatePebble(
                            id: aggregateID(level: level, index: aggregateIndex),
                            createdAt: periodEnd,
                            level: level,
                            pebbleCount: groupSize,
                            childAggregateCount: childIDs.count,
                            grams: groupSize * Constants.Timer.twentyFiveMinutes
                                * Constants.Mass.gramsPerMinute,
                            measuredPebbleCount: groupSize,
                            manualPebbleCount: 0,
                            goldPebbleCount: Int(
                                goldPrefixes[sessionEnd] - goldPrefixes[sessionStart]
                            ),
                            prismPebbleCount: Int(
                                prismPrefixes[sessionEnd] - prismPrefixes[sessionStart]
                            ),
                            colorMixJSON: fixtureColorMixJSON,
                            subjectMixJSON: StrataMath.encodeSubjectMix(subjectMix),
                            periodStart: periodStart,
                            periodEnd: periodEnd,
                            sessionIDs: sessionIDs,
                            childAggregateIDs: childIDs,
                            parentAggregateID: parentID
                        ))
                    }
                    try context.save()
                }
                insertedAggregateCount += batchEnd - batchStart
                insertionPeak = max(insertionPeak, residentBytes())
                progress(Progress(
                    stage: .insertingAggregates,
                    completed: insertedAggregateCount,
                    total: Expected.aggregateCount
                ))
            }
        }
        let insertedAchievementCount = try insertAchievements(
            into: insertionContainer!,
            fixtureStart: fixtureStart
        )
        insertionPeak = max(insertionPeak, residentBytes())
        progress(Progress(
            stage: .insertingAchievements,
            completed: insertedAchievementCount,
            total: Expected.achievementCount
        ))
        let insertionElapsed = elapsedSeconds(since: insertionStartedAt)
        let insertionMemoryAfter = residentBytes()
        let insertion = StageMetrics(
            elapsedSeconds: insertionElapsed,
            rowCount: Expected.subjectCount
                + insertedSessionCount
                + insertedAggregateCount
                + insertedAchievementCount,
            residentBytesBefore: insertionMemoryBefore,
            residentBytesAfter: insertionMemoryAfter,
            peakResidentBytes: max(insertionPeak, insertionMemoryAfter)
        )

        progress(Progress(stage: .fullFetch, completed: 0, total: 1))
        let fetchMemoryBefore = residentBytes()
        let fetchStartedAt = ContinuousClock.now
        var fetchedSubjectCount = 0
        var fetchedSessionCount = 0
        var fetchedAggregateCount = 0
        var fetchedAchievementCount = 0
        var fetchedGoldSessionCount = 0
        var fetchedPrismSessionCount = 0
        var fetchedAggregatesByLevel: [Int: Int] = [:]
        var sessionIDReferenceCount = 0
        var maximumSessionIDsPerAggregate = 0
        var childAggregateIDReferenceCount = 0
        var maximumChildIDsPerAggregate = 0
        var fetchedGrams = 0
        var fetchPeak = fetchMemoryBefore
        try autoreleasepool {
            let context = ModelContext(insertionContainer!)
            context.autosaveEnabled = false
            fetchedSubjectCount = try context.fetchCount(FetchDescriptor<Subject>())
            let sessions = try context.fetch(FetchDescriptor<StudySession>())
            fetchedSessionCount = sessions.count
            fetchedGrams = sessions.reduce(0) { $0 + $1.grams }
            fetchedGoldSessionCount = sessions.filter { $0.pebbleKind == .gold }.count
            fetchedPrismSessionCount = sessions.filter { $0.pebbleKind == .prism }.count
            fetchPeak = max(fetchPeak, residentBytes())
            let aggregates = try context.fetch(FetchDescriptor<AggregatePebble>())
            fetchedAggregateCount = aggregates.count
            fetchedAggregatesByLevel = Dictionary(grouping: aggregates, by: \.level)
                .mapValues(\.count)
            for aggregate in aggregates {
                let sessionCount = aggregate.sessionIDs.count
                let childCount = aggregate.childAggregateIDs.count
                sessionIDReferenceCount += sessionCount
                maximumSessionIDsPerAggregate = max(
                    maximumSessionIDsPerAggregate,
                    sessionCount
                )
                childAggregateIDReferenceCount += childCount
                maximumChildIDsPerAggregate = max(
                    maximumChildIDsPerAggregate,
                    childCount
                )
            }
            fetchedAchievementCount = try context.fetchCount(
                FetchDescriptor<AchievementStone>()
            )
            fetchPeak = max(fetchPeak, residentBytes())
        }
        guard fetchedGrams == Expected.grams else {
            throw HarnessError.persistedMassMismatch
        }
        let fullFetch = StageMetrics(
            elapsedSeconds: elapsedSeconds(since: fetchStartedAt),
            rowCount: fetchedSubjectCount
                + fetchedSessionCount
                + fetchedAggregateCount
                + fetchedAchievementCount,
            residentBytesBefore: fetchMemoryBefore,
            residentBytesAfter: residentBytes(),
            peakResidentBytes: fetchPeak
        )
        progress(Progress(stage: .fullFetch, completed: 1, total: 1))

        // Drop every warm context/container before measuring the exact path an
        // app launch takes. The new container points at the same on-disk store.
        insertionContainer = nil
        try Task.checkCancellation()
        progress(Progress(stage: .coldProjection, completed: 0, total: 1))
        let coldMemoryBefore = residentBytes()
        let coldStartedAt = ContinuousClock.now
        let coldContainer = try makeContainer(storeURL: storeURL)
        let coldContext = ModelContext(coldContainer)
        coldContext.autosaveEnabled = false
        let coldSessionCount = try coldContext.fetchCount(FetchDescriptor<StudySession>())
        let coldAggregateCount = try coldContext.fetchCount(FetchDescriptor<AggregatePebble>())
        let coldAchievementCount = try coldContext.fetchCount(
            FetchDescriptor<AchievementStone>()
        )
        let rootPredicate = #Predicate<AggregatePebble> { aggregate in
            aggregate.parentAggregateID == nil
        }
        let rootDescriptor = FetchDescriptor<AggregatePebble>(
            predicate: rootPredicate,
            sortBy: [SortDescriptor(\AggregatePebble.createdAt)]
        )
        let roots = try coldContext.fetch(rootDescriptor)
        let visibleRoots = AggregatePebblePolicy.visibleRoots(from: roots)
        let coldGoldCount = visibleRoots.reduce(0) { $0 + $1.goldPebbleCount }
        let coldPrismCount = visibleRoots.reduce(0) { $0 + $1.prismPebbleCount }
        let coldAchievements = try coldContext.fetch(FetchDescriptor<AchievementStone>(
            sortBy: [SortDescriptor(\AchievementStone.achievedAt, order: .reverse)]
        ))
        let coldAchievementCountsByKind = Dictionary(
            grouping: coldAchievements,
            by: \.kind
        ).mapValues(\.count)
        let coldVisibleAchievements = AchievementStonePolicy.visibleStones(
            from: coldAchievements
        )
        var looseDescriptor = FetchDescriptor<StudySession>(
            predicate: #Predicate<StudySession> { session in
                session.isBaked == false
            },
            sortBy: [SortDescriptor(\StudySession.endAt, order: .reverse)]
        )
        looseDescriptor.fetchLimit = max(
            0,
            Constants.Jar.maxPhysicsBodies - visibleRoots.count
        )
        let newestLoose = try coldContext.fetch(looseDescriptor)
        let loose = newestLoose.reversed()
        let projectedStudyDescriptors = visibleRoots.map(PebbleDescriptor.init(aggregate:))
            + loose.map(PebbleDescriptor.init(session:))
        let projectedDescriptors = projectedStudyDescriptors
            + coldVisibleAchievements.map(PebbleDescriptor.init(achievement:))
        let representedPebbleCount = visibleRoots.reduce(0) { $0 + $1.pebbleCount }
            + loose.count
        let representedGrams = visibleRoots.reduce(0) { $0 + $1.grams }
            + loose.reduce(0) { $0 + $1.grams }
        let projectedQueueCount = max(
            0,
            projectedDescriptors.count - Constants.Jar.maxPhysicsBodies
        )
        let coldPeak = residentBytes()
        let coldProjection = StageMetrics(
            elapsedSeconds: elapsedSeconds(since: coldStartedAt),
            rowCount: projectedDescriptors.count,
            residentBytesBefore: coldMemoryBefore,
            residentBytesAfter: coldPeak,
            peakResidentBytes: coldPeak
        )
        progress(Progress(stage: .coldProjection, completed: 1, total: 1))

        let storeBytes = directorySize(at: directory)
        progress(Progress(stage: .finishing, completed: 1, total: 1))
        return Report(
            storeBytes: storeBytes,
            insertion: insertion,
            fullFetch: fullFetch,
            coldProjection: coldProjection,
            insertedSessionCount: insertedSessionCount,
            insertedAggregateCount: insertedAggregateCount,
            insertedAchievementCount: insertedAchievementCount,
            fetchedSubjectCount: fetchedSubjectCount,
            fetchedSessionCount: fetchedSessionCount,
            fetchedAggregateCount: fetchedAggregateCount,
            fetchedAchievementCount: fetchedAchievementCount,
            fetchedGoldSessionCount: fetchedGoldSessionCount,
            fetchedPrismSessionCount: fetchedPrismSessionCount,
            fetchedAggregatesByLevel: fetchedAggregatesByLevel,
            sessionIDReferenceCount: sessionIDReferenceCount,
            maximumSessionIDsPerAggregate: maximumSessionIDsPerAggregate,
            childAggregateIDReferenceCount: childAggregateIDReferenceCount,
            maximumChildIDsPerAggregate: maximumChildIDsPerAggregate,
            coldSessionCount: coldSessionCount,
            coldAggregateCount: coldAggregateCount,
            coldRootAggregateCount: roots.count,
            coldLooseSessionCount: loose.count,
            coldAchievementCount: coldAchievementCount,
            coldVisibleAchievementCount: coldVisibleAchievements.count,
            coldAchievementCountsByKind: coldAchievementCountsByKind,
            coldGoldCount: coldGoldCount,
            coldPrismCount: coldPrismCount,
            projectedDescriptorCount: projectedDescriptors.count,
            projectedQueueCount: projectedQueueCount,
            representedPebbleCount: representedPebbleCount,
            representedGrams: representedGrams,
            goldCount: goldCount,
            prismCount: prismCount
        )
    }

    private static func makeContainer(storeURL: URL) throws -> ModelContainer {
        let schema = Schema([
            Subject.self,
            StudySession.self,
            AchievementStone.self,
            AggregatePebble.self,
            Stratum.self,
            Bedrock.self,
            GachaState.self,
            Prefs.self,
            ActivityResetMarker.self,
            SyncedFocusTimer.self,
            FocusTimerDeviceClaim.self
        ])
        let configuration = ModelConfiguration(
            "FortyYearPersistenceHarness",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private static func insertSubjects(into container: ModelContainer, createdAt: Date) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        for (index, fixture) in fixtureSubjects.enumerated() {
            context.insert(Subject(
                id: fixture.id,
                name: fixture.name,
                colorHex: fixture.colorHex,
                sortOrder: index,
                createdAt: createdAt
            ))
        }
        try context.save()
    }

    @discardableResult
    private static func insertAchievements(
        into container: ModelContainer,
        fixtureStart: Date
    ) throws -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var insertedCount = 0

        for yearOffset in 0 ..< 40 {
            for (kindIndex, kind) in AchievementKind.allCases.enumerated() {
                let achievedAt = calendar.date(
                    byAdding: .year,
                    value: yearOffset,
                    to: fixtureStart
                )?.addingTimeInterval(TimeInterval(kindIndex * 60)) ?? fixtureStart
                let subject = fixtureSubjects[(yearOffset + kindIndex) % fixtureSubjects.count]
                context.insert(AchievementStone(
                    id: achievementID(index: insertedCount),
                    kind: kind,
                    achievedAt: achievedAt,
                    createdAt: achievedAt,
                    subjectNameSnapshot: subject.name,
                    subjectColorHexSnapshot: subject.colorHex
                ))
                insertedCount += 1
            }
        }
        try context.save()
        return insertedCount
    }

    private static var fixtureStartDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        return calendar.date(from: DateComponents(
            year: 1985,
            month: 1,
            day: 1,
            hour: 8
        ))!
    }

    private static func makeDayKeys(startingAt start: Date) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)
        formatter.dateFormat = "yyyy-MM-dd"
        return (0 ..< FortyYearDebugScenario.Expected.dayCount).map { dayIndex in
            formatter.string(from: start.addingTimeInterval(TimeInterval(dayIndex * 86_400)))
        }
    }

    private static func fixtureDate(
        fixtureStart: Date,
        globalSessionIndex: Int
    ) -> Date {
        fixtureDate(
            fixtureStart: fixtureStart,
            dayIndex: globalSessionIndex
                / FortyYearDebugScenario.Expected.focusSessionsPerDay,
            slot: globalSessionIndex
                % FortyYearDebugScenario.Expected.focusSessionsPerDay
        )
    }

    private static func fixtureDate(
        fixtureStart: Date,
        dayIndex: Int,
        slot: Int
    ) -> Date {
        fixtureStart.addingTimeInterval(
            TimeInterval(dayIndex * 86_400 + slot * 1_800)
        )
    }

    private static func decimalPower(_ level: Int) -> Int {
        (0 ..< level).reduce(1) { value, _ in value * Constants.Jar.aggregateFanIn }
    }

    private static func sessionID(index: Int) -> UUID {
        deterministicUUID(index: index, namespace: 0x5345_5353_494F_4E00)
    }

    private static func aggregateID(level: Int, index: Int) -> UUID {
        // Encode the level into the ordinal. Using `namespace ^ level` together
        // with `index ^ namespace` made distinct hierarchy rows share a UUID.
        let scopedIndex = (level << 32) | index
        return deterministicUUID(
            index: scopedIndex,
            namespace: 0x5045_5253_4953_5400
        )
    }

    private static func achievementID(index: Int) -> UUID {
        deterministicUUID(index: index, namespace: 0x4143_4849_4556_4500)
    }

    private static func deterministicUUID(index: Int, namespace: UInt64) -> UUID {
        let high = mixed(UInt64(index) ^ namespace)
        let low = mixed(UInt64(index) &+ namespace &+ 0x9E37_79B9_7F4A_7C15)
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: high >> 56),
            UInt8(truncatingIfNeeded: high >> 48),
            UInt8(truncatingIfNeeded: high >> 40),
            UInt8(truncatingIfNeeded: high >> 32),
            UInt8(truncatingIfNeeded: high >> 24),
            UInt8(truncatingIfNeeded: high >> 16),
            (UInt8(truncatingIfNeeded: high >> 8) & 0x0F) | 0x80,
            UInt8(truncatingIfNeeded: high),
            (UInt8(truncatingIfNeeded: low >> 56) & 0x3F) | 0x80,
            UInt8(truncatingIfNeeded: low >> 48),
            UInt8(truncatingIfNeeded: low >> 40),
            UInt8(truncatingIfNeeded: low >> 32),
            UInt8(truncatingIfNeeded: low >> 24),
            UInt8(truncatingIfNeeded: low >> 16),
            UInt8(truncatingIfNeeded: low >> 8),
            UInt8(truncatingIfNeeded: low)
        ))
    }

    private static func mixed(_ input: UInt64) -> UInt64 {
        var value = input &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    private static func elapsedSeconds(
        since start: ContinuousClock.Instant
    ) -> TimeInterval {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func residentBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    private static func directorySize(at directory: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let url as URL in enumerator {
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            total += UInt64(max(0, size ?? 0))
        }
        return total
    }

    private struct FixtureSubject: Sendable {
        let id: UUID
        let name: String
        let colorHex: String
    }

    private static let fixtureSubjects: [FixtureSubject] = [
        FixtureSubject(
            id: deterministicUUID(index: 0, namespace: 0x5355_424A_4543_5400),
            name: "資格",
            colorHex: "#FF647F"
        ),
        FixtureSubject(
            id: deterministicUUID(index: 1, namespace: 0x5355_424A_4543_5400),
            name: "英語",
            colorHex: Constants.Color.english
        ),
        FixtureSubject(
            id: deterministicUUID(index: 2, namespace: 0x5355_424A_4543_5400),
            name: "数学",
            colorHex: Constants.Color.mathematics
        ),
        FixtureSubject(
            id: deterministicUUID(index: 3, namespace: 0x5355_424A_4543_5400),
            name: "仕事",
            colorHex: "#28C7A0"
        ),
        FixtureSubject(
            id: deterministicUUID(index: 4, namespace: 0x5355_424A_4543_5400),
            name: "研究",
            colorHex: "#A979FF"
        )
    ]

    private static let fixtureColorMixJSON = StrataMath.encodeColorMix(
        fixtureSubjects.map {
            StratumColorFraction(
                hex: $0.colorHex,
                fraction: 1 / Double(fixtureSubjects.count)
            )
        }
    )

    private struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func nextUnitDouble() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            value ^= value >> 31
            return Double(value >> 11) / Double(UInt64(1) << 53)
        }
    }

    private enum HarnessError: LocalizedError {
        case explicitOptInRequired
        case invalidBatchSize
        case storeUnavailable
        case rewardFixtureMismatch
        case aggregateFixtureMismatch
        case persistedMassMismatch

        var errorDescription: String? {
            switch self {
            case .explicitOptInRequired:
                "\(optInEnvironmentKey)=1 を設定したDebugプロセスでだけ実行できます。"
            case .invalidBatchSize:
                "保存バッチ件数は1以上にしてください。"
            case .storeUnavailable:
                "隔離SwiftDataストアを開けませんでした。"
            case .rewardFixtureMismatch:
                "レア粒fixtureが算術シミュレーションと一致しません。"
            case .aggregateFixtureMismatch:
                "まとまり階層fixtureが期待値と一致しません。"
            case .persistedMassMismatch:
                "fetchした質量が87.66tと一致しません。"
            }
        }
    }
}
#endif
