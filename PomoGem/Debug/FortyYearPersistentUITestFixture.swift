#if DEBUG && targetEnvironment(simulator)
import Foundation
import SwiftData
import SwiftUI

/// Real, CloudKit-free, named persistent store used only by the cold-launch UI
/// test. It never aliases the ordinary Debug simulator or user iCloud store.
enum FortyYearPersistentUITestFixture {
    static let storeEnvironmentKey = "POMOGEM_UI_TEST_PERSISTENT_STORE"
    static let actionEnvironmentKey = "POMOGEM_UI_TEST_PERSISTENT_ACTION"
    static let overviewEnvironmentKey = "POMOGEM_UI_TEST_FORTY_YEAR_OVERVIEW"

    enum Action: String {
        case normal
        case seed
        case clean
    }

    struct Request {
        let name: String
        let action: Action
        let storeURL: URL
    }

    enum Expected {
        static let sessionCount = 350_640
        static let bakedSessionCount = 350_640
        static let looseSessionCount = 0
        static let aggregateCount = 38_958
        static let rootCount = 18
        static let grams = 87_660_000
        static let projectedBodyCount = 18
        static let queueCount = 0
        static let aggregateCountsByLevel = [
            1: 35_064,
            2: 3_506,
            3: 350,
            4: 35,
            5: 3
        ]
    }

    static var isActiveForCurrentProcess: Bool {
        request(environment: ProcessInfo.processInfo.environment) != nil
    }

    static var showsOverviewForCurrentProcess: Bool {
        LocalPreviewLaunchPolicy.isUITestModeForCurrentProcess
            && ProcessInfo.processInfo.environment[overviewEnvironmentKey] == "1"
    }

    static let overviewClusters: [AccumulationClusterSummary] = {
        let snapshot = FusionHierarchyPresentation.snapshot(
            totalPebbleCount: Expected.sessionCount
        )
        let base = Date(timeIntervalSince1970: 473_385_600) // 1985-01-01 UTC
        let palette = [
            Constants.Color.english,
            Constants.Color.mathematics,
            Constants.Color.science,
            Constants.Color.socialStudies
        ]
        var sequence = 0
        return snapshot.activeLevels
            .filter { $0.level > 0 }
            .flatMap { hierarchyLevel -> [AccumulationClusterSummary] in
                (0..<hierarchyLevel.unitCount).map { index in
                    let color = palette[(hierarchyLevel.level + index) % palette.count]
                    let end = base.addingTimeInterval(Double(sequence) * 86_400)
                    sequence += 1
                    return AccumulationClusterSummary(
                        id: UUID(),
                        level: hierarchyLevel.level,
                        pebbleCount: hierarchyLevel.unitPebbleCount,
                        grams: hierarchyLevel.unitPebbleCount
                            * Constants.Mass.measuredPebbleGrams,
                        periodStart: base,
                        periodEnd: end,
                        colorMix: [StratumColorFraction(hex: color, fraction: 1)],
                        subjectMix: [AggregateSubjectFraction(
                            name: "40年の集中",
                            colorHex: color,
                            pebbleCount: hierarchyLevel.unitPebbleCount
                        )],
                        childCount: hierarchyLevel.level > 1
                            ? Constants.Jar.aggregateFanIn
                            : 0,
                        sessionIDs: [],
                        measuredPebbleCount: hierarchyLevel.unitPebbleCount,
                        manualPebbleCount: 0,
                        goldPebbleCount: index == 0 ? 1 : 0,
                        prismPebbleCount: index == hierarchyLevel.unitCount - 1 ? 1 : 0
                    )
                }
            }
    }()

    static var actionForCurrentProcess: Action? {
        request(environment: ProcessInfo.processInfo.environment)?.action
    }

    static func request(environment: [String: String]) -> Request? {
        guard let rawName = environment[storeEnvironmentKey],
              let name = safeStoreName(rawName)
        else { return nil }
        let action = Action(
            rawValue: environment[actionEnvironmentKey]?.lowercased() ?? "normal"
        ) ?? .normal
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = support
            .appendingPathComponent("PomoGemPersistentUITestStores", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        return Request(
            name: name,
            action: action,
            storeURL: directory.appendingPathComponent("PomoGem.store")
        )
    }

    static func makeConfiguration(
        schema: Schema,
        request: Request
    ) throws -> ModelConfiguration {
        let directory = request.storeURL.deletingLastPathComponent()
        if request.action == .seed || request.action == .clean {
            try safelyRemoveStoreDirectory(directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return ModelConfiguration(
            "PomoGemPersistentUITest",
            schema: schema,
            url: request.storeURL,
            cloudKitDatabase: .none
        )
    }

    static func seed(in container: ModelContainer) async throws -> Verification {
        try await Task.detached(priority: .utility) {
            try seedSynchronously(in: container)
        }.value
    }

    private static func seedSynchronously(
        in container: ModelContainer
    ) throws -> Verification {
        let initialContext = ModelContext(container)
        initialContext.autosaveEnabled = false
        let existingSessions = try initialContext.fetchCount(FetchDescriptor<StudySession>())
        let existingAggregates = try initialContext.fetchCount(FetchDescriptor<AggregatePebble>())
        guard existingSessions == 0, existingAggregates == 0 else {
            throw FixtureError.storeWasNotClean(
                sessions: existingSessions,
                aggregates: existingAggregates
            )
        }

        let fixtureStart = fixtureStartDate
        let subjects = fixtureSubjects
        for (index, subject) in subjects.enumerated() {
            initialContext.insert(Subject(
                id: subject.id,
                name: subject.name,
                colorHex: subject.colorHex,
                sortOrder: index,
                createdAt: fixtureStart
            ))
        }
        initialContext.insert(Prefs(
            hasCompletedOnboarding: true,
            usagePurposeRawValue: UsagePurpose.study.rawValue,
            hasCompletedInitialSubjectSeed: true
        ))
        try initialContext.save()

        let sessionBatchSize = 4_000
        for batchStart in stride(from: 0, to: Expected.sessionCount, by: sessionBatchSize) {
            let batchEnd = min(batchStart + sessionBatchSize, Expected.sessionCount)
            try autoreleasepool {
                let context = ModelContext(container)
                context.autosaveEnabled = false
                for index in batchStart ..< batchEnd {
                    let subject = subjects[index % subjects.count]
                    let startAt = fixtureDate(globalSessionIndex: index)
                    context.insert(StudySession(
                        id: sessionID(index: index),
                        startAt: startAt,
                        endAt: startAt.addingTimeInterval(1_500),
                        seconds: 1_500,
                        source: .timer,
                        pebbleKind: .normal,
                        grams: 250,
                        deviceDayKey: "fixture-\(index / 24)",
                        isBaked: index < Expected.bakedSessionCount,
                        subjectNameSnapshot: subject.name,
                        subjectColorHexSnapshot: subject.colorHex,
                        subjectIDSnapshot: subject.id
                    ))
                }
                try context.save()
            }
        }

        let aggregateBatchSize = 500
        for level in 1 ... 5 {
            guard let count = Expected.aggregateCountsByLevel[level] else {
                throw FixtureError.invalidExpectedHierarchy
            }
            let groupSize = decimalPower(level)
            for batchStart in stride(from: 0, to: count, by: aggregateBatchSize) {
                let batchEnd = min(batchStart + aggregateBatchSize, count)
                try autoreleasepool {
                    let context = ModelContext(container)
                    context.autosaveEnabled = false
                    for aggregateIndex in batchStart ..< batchEnd {
                        let sessionStart = aggregateIndex * groupSize
                        let sessionEnd = sessionStart + groupSize
                        let sessionIDs = level == 1
                            ? (sessionStart ..< sessionEnd).map(sessionID(index:))
                            : []
                        let childIDs = level == 1
                            ? []
                            : (aggregateIndex * Constants.Jar.aggregateFanIn
                                ..< (aggregateIndex + 1) * Constants.Jar.aggregateFanIn)
                                .map { aggregateID(level: level - 1, index: $0) }
                        let parentID: UUID?
                        if let parentCount = Expected.aggregateCountsByLevel[level + 1],
                           aggregateIndex < parentCount * Constants.Jar.aggregateFanIn {
                            parentID = aggregateID(
                                level: level + 1,
                                index: aggregateIndex / Constants.Jar.aggregateFanIn
                            )
                        } else {
                            parentID = nil
                        }
                        let periodStart = fixtureDate(globalSessionIndex: sessionStart)
                        let periodEnd = fixtureDate(globalSessionIndex: sessionEnd - 1)
                            .addingTimeInterval(1_500)
                        context.insert(AggregatePebble(
                            id: aggregateID(level: level, index: aggregateIndex),
                            createdAt: periodEnd,
                            level: level,
                            pebbleCount: groupSize,
                            childAggregateCount: childIDs.count,
                            grams: groupSize * 250,
                            measuredPebbleCount: groupSize,
                            manualPebbleCount: 0,
                            goldPebbleCount: 0,
                            prismPebbleCount: 0,
                            colorMixJSON: fixtureColorMixJSON,
                            subjectMixJSON: fixtureSubjectMixJSON(pebbleCount: groupSize),
                            periodStart: periodStart,
                            periodEnd: periodEnd,
                            sessionIDs: sessionIDs,
                            childAggregateIDs: childIDs,
                            parentAggregateID: parentID
                        ))
                    }
                    try context.save()
                }
            }
        }
        return try verify(container: container)
    }

    static func verify(container: ModelContainer) throws -> Verification {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let sessionCount = try context.fetchCount(FetchDescriptor<StudySession>())
        let aggregateCount = try context.fetchCount(FetchDescriptor<AggregatePebble>())
        let rootCount = try context.fetchCount(FetchDescriptor<AggregatePebble>(
            predicate: #Predicate { aggregate in aggregate.parentAggregateID == nil }
        ))
        let roots = try context.fetch(FetchDescriptor<AggregatePebble>(
            predicate: #Predicate { aggregate in aggregate.parentAggregateID == nil }
        ))
        let newestRootEnd = roots.map(\.periodEnd).max() ?? .distantPast
        let looseCount = try context.fetchCount(FetchDescriptor<StudySession>(
            predicate: #Predicate { session in session.endAt > newestRootEnd }
        ))
        let aggregates = try context.fetch(FetchDescriptor<AggregatePebble>())
        let aggregateGroups = Dictionary(grouping: aggregates, by: \.id)
        let uniqueAggregateCount = aggregateGroups.count
        let aggregatesByID = aggregateGroups.compactMapValues(\.first)
        let hierarchyIsClosed = uniqueAggregateCount == aggregateCount
            && aggregates.allSatisfy { aggregate in
                let childIDs = Set(aggregate.childAggregateIDs)
                guard childIDs.count == aggregate.childAggregateCount else { return false }
                return childIDs.allSatisfy { childID in
                    aggregatesByID[childID]?.parentAggregateID == aggregate.id
                }
            }
        var looseDescriptor = FetchDescriptor<StudySession>(
            predicate: #Predicate { session in session.endAt > newestRootEnd }
        )
        looseDescriptor.fetchLimit = Expected.looseSessionCount + 1
        let loose = try context.fetch(looseDescriptor)
        let grams = roots.reduce(0) { $0 + $1.grams }
            + loose.reduce(0) { $0 + $1.grams }
        let projectedBodies = roots.count + loose.count
        let result = Verification(
            sessionCount: sessionCount,
            aggregateCount: aggregateCount,
            uniqueAggregateCount: uniqueAggregateCount,
            hierarchyIsClosed: hierarchyIsClosed,
            rootCount: rootCount,
            looseCount: looseCount,
            grams: grams,
            projectedBodyCount: projectedBodies,
            queueCount: 0
        )
        guard result.passed else { throw FixtureError.verificationFailed(result) }
        return result
    }

    struct Verification: Equatable, Sendable {
        let sessionCount: Int
        let aggregateCount: Int
        let uniqueAggregateCount: Int
        let hierarchyIsClosed: Bool
        let rootCount: Int
        let looseCount: Int
        let grams: Int
        let projectedBodyCount: Int
        let queueCount: Int

        var passed: Bool {
            sessionCount == Expected.sessionCount
                && aggregateCount == Expected.aggregateCount
                && uniqueAggregateCount == Expected.aggregateCount
                && hierarchyIsClosed
                && rootCount == Expected.rootCount
                && looseCount == Expected.looseSessionCount
                && grams == Expected.grams
                && projectedBodyCount == Expected.projectedBodyCount
                && queueCount == Expected.queueCount
        }

        var accessibilityValue: String {
            "sessions=\(sessionCount);aggregates=\(aggregateCount);uniqueAggregates=\(uniqueAggregateCount);hierarchyClosed=\(hierarchyIsClosed);grams=\(grams);roots=\(rootCount);loose=\(looseCount);bodies=\(projectedBodyCount);queue=\(queueCount)"
        }
    }

    private static func safelyRemoveStoreDirectory(_ directory: URL) throws {
        let base = directory.deletingLastPathComponent().standardizedFileURL
        let target = directory.standardizedFileURL
        guard target.deletingLastPathComponent() == base,
              base.lastPathComponent == "PomoGemPersistentUITestStores"
        else { throw FixtureError.unsafeStorePath }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    private static func safeStoreName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(trimmed.count),
              trimmed.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || scalar == "-" || scalar == "_" || scalar == "."
              }),
              trimmed != ".",
              trimmed != ".."
        else { return nil }
        return trimmed
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

    private static func fixtureDate(globalSessionIndex index: Int) -> Date {
        fixtureStartDate.addingTimeInterval(
            TimeInterval((index / 24) * 86_400 + (index % 24) * 1_800)
        )
    }

    private static func decimalPower(_ level: Int) -> Int {
        (0 ..< level).reduce(1) { value, _ in
            value * Constants.Jar.aggregateFanIn
        }
    }

    private static func sessionID(index: Int) -> UUID {
        deterministicUUID(index: index, namespace: 0x5345_5353_5549_0000)
    }

    private static func aggregateID(level: Int, index: Int) -> UUID {
        // Keep hierarchy scope in the ordinal itself. XOR-ing `level` into the
        // namespace lets neighboring level/index pairs cancel each other and
        // produced 1,157 duplicate IDs in the 40-year fixture.
        let scopedIndex = (level << 32) | index
        return deterministicUUID(
            index: scopedIndex,
            namespace: 0x4147_4752_5549_0000
        )
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

    private struct FixtureSubject {
        let id: UUID
        let name: String
        let colorHex: String
    }

    private static let fixtureSubjects: [FixtureSubject] = [
        FixtureSubject(id: deterministicUUID(index: 0, namespace: 0x5355_424A_0000_0000), name: "資格", colorHex: "#FF647F"),
        FixtureSubject(id: deterministicUUID(index: 1, namespace: 0x5355_424A_0000_0000), name: "英語", colorHex: Constants.Color.english),
        FixtureSubject(id: deterministicUUID(index: 2, namespace: 0x5355_424A_0000_0000), name: "数学", colorHex: Constants.Color.mathematics),
        FixtureSubject(id: deterministicUUID(index: 3, namespace: 0x5355_424A_0000_0000), name: "仕事", colorHex: "#28C7A0"),
        FixtureSubject(id: deterministicUUID(index: 4, namespace: 0x5355_424A_0000_0000), name: "研究", colorHex: "#A979FF")
    ]

    private static let fixtureColorMixJSON = StrataMath.encodeColorMix(
        fixtureSubjects.map {
            StratumColorFraction(
                hex: $0.colorHex,
                fraction: 1 / Double(fixtureSubjects.count)
            )
        }
    )

    private static func fixtureSubjectMixJSON(pebbleCount: Int) -> String {
        StrataMath.encodeSubjectMix(fixtureSubjects.map {
            AggregateSubjectFraction(
                name: $0.name,
                colorHex: $0.colorHex,
                pebbleCount: pebbleCount / fixtureSubjects.count
            )
        })
    }

    private enum FixtureError: LocalizedError {
        case unsafeStorePath
        case storeWasNotClean(sessions: Int, aggregates: Int)
        case invalidExpectedHierarchy
        case verificationFailed(Verification)

        var errorDescription: String? {
            switch self {
            case .unsafeStorePath:
                "UIテスト専用ストア以外は削除できません。"
            case let .storeWasNotClean(sessions, aggregates):
                "fixture storeが空ではありません (sessions=\(sessions), aggregates=\(aggregates))。"
            case .invalidExpectedHierarchy:
                "40年fixtureの階層定義が不正です。"
            case let .verificationFailed(value):
                "40年fixtureの検証に失敗しました: \(value.accessibilityValue)"
            }
        }
    }
}

struct FortyYearPersistentFixtureLaunchView: View {
    let container: ModelContainer
    let action: FortyYearPersistentUITestFixture.Action

    @State private var verification: FortyYearPersistentUITestFixture.Verification?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            NightBackground()
            VStack(spacing: 18) {
                if action == .clean {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.largeTitle)
                    Text("専用fixtureを消去しました")
                        .accessibilityIdentifier("fixture.40y.cleaned")
                } else if let verification {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.largeTitle)
                    Text("40年fixtureの準備完了")
                        .accessibilityIdentifier("fixture.40y.ready")
                        .accessibilityValue(verification.accessibilityValue)
                } else if let errorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("fixture.40y.error")
                } else {
                    ProgressView()
                    Text("40年分を専用ストアへ保存しています")
                        .accessibilityIdentifier("fixture.40y.seeding")
                }
            }
            .padding(24)
        }
        .task {
            guard action == .seed else { return }
            do {
                verification = try await FortyYearPersistentUITestFixture.seed(in: container)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct FortyYearOverviewFixtureLaunchView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var timelineFixtureIsReady = false
    @State private var timelineFixtureError: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AccumulationOverviewView(
                records: [],
                clusters: FortyYearPersistentUITestFixture.overviewClusters,
                milestones: [],
                lifetimeGrams: FortyYearPersistentUITestFixture.Expected.grams,
                lifetimePebbleCount: FortyYearPersistentUITestFixture.Expected.sessionCount,
                pageScope: AccumulationOverviewPageScope(
                    totalSessionCount: FortyYearPersistentUITestFixture.Expected.sessionCount,
                    displayedSessionCount: 0,
                    totalAchievementCount: 0,
                    displayedAchievementCount: 0
                ),
                lifetimeIsLowerBound: false,
                lifetimeIsCloudUnverified: false,
                initialClusterID: nil
            )

            if timelineFixtureIsReady {
                Text("年月データ準備済み")
                    .font(.caption2)
                    .foregroundStyle(PomoGemTheme.muted)
                    .padding(6)
                    .accessibilityIdentifier("fixture.40y.timeline-ready")
            } else if let timelineFixtureError {
                Text(timelineFixtureError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(6)
                    .accessibilityIdentifier("fixture.40y.timeline-error")
            }
        }
        .preferredColorScheme(.dark)
        .tint(PomoGemTheme.amber)
        .task { prepareTimelineFixtureIfNeeded() }
    }

    @MainActor
    private func prepareTimelineFixtureIfNeeded() {
        // A named persistent fixture already contains its real 350,640 rows.
        // Only the in-memory visual fixture needs lightweight boundary data.
        guard LocalPreviewLaunchPolicy.persistenceModeForCurrentProcess == .inMemoryPreview else {
            timelineFixtureIsReady = true
            return
        }
        do {
            guard try modelContext.fetchCount(FetchDescriptor<StudySession>()) == 0 else {
                timelineFixtureIsReady = true
                return
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
            let oldestMonth = calendar.date(from: DateComponents(
                year: 1985,
                month: 1,
                day: 15,
                hour: 12
            ))!
            for index in 0 ..< 110 {
                let endAt = oldestMonth.addingTimeInterval(Double(index * 60))
                modelContext.insert(StudySession(
                    startAt: endAt.addingTimeInterval(-1_500),
                    endAt: endAt,
                    seconds: 1_500,
                    source: .timer,
                    grams: 250,
                    deviceDayKey: "timeline-1985",
                    subjectNameSnapshot: "40年の集中",
                    subjectColorHexSnapshot: Constants.Color.mathematics
                ))
            }
            for index in 0 ..< 2 {
                let endAt = calendar.date(from: DateComponents(
                    year: 2024,
                    month: 12,
                    day: 15 + index,
                    hour: 12
                ))!
                modelContext.insert(StudySession(
                    startAt: endAt.addingTimeInterval(-1_500),
                    endAt: endAt,
                    seconds: 1_500,
                    source: .timer,
                    grams: 250,
                    deviceDayKey: "timeline-2024",
                    subjectNameSnapshot: "40年の集中",
                    subjectColorHexSnapshot: Constants.Color.auroraWarm
                ))
            }
            try modelContext.save()
            timelineFixtureIsReady = true
        } catch {
            timelineFixtureError = error.localizedDescription
        }
    }
}
#endif
