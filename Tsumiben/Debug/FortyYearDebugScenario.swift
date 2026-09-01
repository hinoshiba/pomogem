#if DEBUG
import Foundation

/// A deterministic, developer-only arithmetic and bounded-physics simulation.
///
/// The audit deliberately streams every focus through the real timer and
/// reward engines, but retains only the bounded set of bodies that the live jar
/// would need. It never opens or writes a ModelContainer and therefore makes no
/// claim about persistence performance. `FortyYearPersistenceHarness` is the
/// separate, explicitly opted-in real-store audit.
enum FortyYearDebugScenario {
    enum Expected {
        static let dayCount = 14_610
        static let focusSessionsPerDay = 24
        static let completionCount = dayCount * focusSessionsPerDay
        static let focusMinutes = completionCount * Constants.Timer.twentyFiveMinutes
        static let focusHours = focusMinutes / Constants.Timer.secondsPerMinute
        static let focusSeconds = focusMinutes * Constants.Timer.secondsPerMinute
        static let grams = focusMinutes * Constants.Mass.gramsPerMinute
        static let shortBreakCount = completionCount * 3 / 4
        static let longBreakCount = completionCount / 4

        static let normalCount = 313_820
        static let goldCount = 34_067
        static let prismCount = 2_753
        static let pityGoldCount = 6_315
        static let finalMissesSinceGold = 4

        static let achievementCount = 40 * AchievementKind.allCases.count
        static let visibleAchievementCount = Constants.Jar.maximumVisibleAchievementStones
        static let studyBodyCount = 18
        static let renderedBodyCount = studyBodyCount + visibleAchievementCount
        static let aggregateCreationCount = 38_958

        static let finalBodiesByLevel: [Int: Int] = [
            1: 4,
            2: 6,
            4: 5,
            5: 3
        ]
        static let aggregateCreationsByLevel: [Int: Int] = [
            1: 35_064,
            2: 3_506,
            3: 350,
            4: 35,
            5: 3
        ]
    }

    struct Progress: Equatable, Sendable {
        let completedDays: Int
        let completedSessions: Int

        var fraction: Double {
            Double(completedDays) / Double(Expected.dayCount)
        }
    }

    struct SubjectTotal: Identifiable, Equatable, Sendable {
        let name: String
        let colorHex: String
        let pebbleCount: Int

        var id: String { "\(name)-\(colorHex)" }
    }

    struct BodySnapshot: Identifiable, Equatable, Sendable {
        let id: UUID
        let level: Int
        let pebbleCount: Int
        let grams: Int
        let colorMix: [StratumColorFraction]
        let subjectMix: [AggregateSubjectFraction]
        let periodStart: Date
        let periodEnd: Date
        let goldPebbleCount: Int
        let prismPebbleCount: Int
        let kind: PebbleKind

        var isAggregate: Bool { level > 0 }

        var descriptor: PebbleDescriptor {
            if isAggregate {
                let metadata = AggregateMetadata(
                    level: level,
                    pebbleCount: pebbleCount,
                    childAggregateCount: level > 1 ? Constants.Jar.aggregateFanIn : 0,
                    colorMix: colorMix,
                    subjectMix: subjectMix,
                    periodStart: periodStart,
                    periodEnd: periodEnd,
                    sessionIDs: [],
                    measuredPebbleCount: pebbleCount,
                    manualPebbleCount: 0,
                    goldPebbleCount: goldPebbleCount,
                    prismPebbleCount: prismPebbleCount
                )
                return PebbleDescriptor(
                    id: id,
                    subjectName: metadata.primarySubjectName,
                    colorHex: metadata.dominantColorHex,
                    source: .timer,
                    kind: .normal,
                    aggregate: metadata,
                    grams: grams,
                    radius: CGFloat(StrataMath.aggregateRadius(level: level)),
                    createdAt: periodEnd
                )
            }

            return PebbleDescriptor(
                id: id,
                subjectName: subjectMix.first?.name ?? "過去の集中",
                colorHex: subjectMix.first?.colorHex ?? Constants.Color.textMute,
                source: .timer,
                kind: kind,
                grams: grams,
                createdAt: periodEnd
            )
        }
    }

    struct AchievementSnapshot: Identifiable, Equatable, Sendable {
        let id: UUID
        let kind: AchievementKind
        let subjectName: String
        let colorHex: String
        let achievedAt: Date

        var descriptor: PebbleDescriptor {
            PebbleDescriptor(
                id: id,
                subjectName: subjectName,
                colorHex: colorHex,
                source: .manual,
                kind: .normal,
                achievementKind: kind,
                grams: 0,
                createdAt: achievedAt
            )
        }
    }

    struct Report: Equatable, Sendable {
        let startedAt: Date
        let endedAt: Date
        let elapsedSeconds: TimeInterval
        let dayCount: Int
        let completionCount: Int
        let focusSeconds: Int
        let grams: Int
        let shortBreakCount: Int
        let longBreakCount: Int
        let normalCount: Int
        let goldCount: Int
        let prismCount: Int
        let pityGoldCount: Int
        let finalMissesSinceGold: Int
        let maximumStudyBodyCount: Int
        let aggregateCreationCount: Int
        let aggregateCreationsByLevel: [Int: Int]
        let bodies: [BodySnapshot]
        let achievements: [AchievementSnapshot]
        let subjectTotals: [SubjectTotal]

        var focusHours: Int { focusSeconds / 3_600 }
        var pebbleCount: Int { bodies.reduce(0) { $0 + $1.pebbleCount } }
        var studyBodyCount: Int { bodies.count }
        var visibleAchievements: [AchievementSnapshot] {
            Array(achievements.suffix(Expected.visibleAchievementCount))
        }
        var renderedBodyCount: Int { studyBodyCount + visibleAchievements.count }
        var bodiesByLevel: [Int: Int] {
            Dictionary(grouping: bodies, by: \.level).mapValues(\.count)
        }
        var descriptors: [PebbleDescriptor] {
            bodies.map(\.descriptor) + visibleAchievements.map(\.descriptor)
        }
        var retainedGoldCount: Int { bodies.reduce(0) { $0 + $1.goldPebbleCount } }
        var retainedPrismCount: Int { bodies.reduce(0) { $0 + $1.prismPebbleCount } }
        var achievementCountsByKind: [AchievementKind: Int] {
            Dictionary(grouping: achievements, by: \.kind).mapValues(\.count)
        }

        var passed: Bool {
            dayCount == Expected.dayCount
                && completionCount == Expected.completionCount
                && focusSeconds == Expected.focusSeconds
                && focusHours == Expected.focusHours
                && grams == Expected.grams
                && shortBreakCount == Expected.shortBreakCount
                && longBreakCount == Expected.longBreakCount
                && normalCount == Expected.normalCount
                && goldCount == Expected.goldCount
                && prismCount == Expected.prismCount
                && retainedGoldCount == goldCount
                && retainedPrismCount == prismCount
                && pityGoldCount == Expected.pityGoldCount
                && finalMissesSinceGold == Expected.finalMissesSinceGold
                && pebbleCount == Expected.completionCount
                && studyBodyCount == Expected.studyBodyCount
                && renderedBodyCount == Expected.renderedBodyCount
                && maximumStudyBodyCount <= Constants.Jar.maxPhysicsBodies
                && aggregateCreationCount == Expected.aggregateCreationCount
                && aggregateCreationsByLevel == Expected.aggregateCreationsByLevel
                && bodiesByLevel == Expected.finalBodiesByLevel
                && achievements.count == Expected.achievementCount
                && visibleAchievements.count == Expected.visibleAchievementCount
                && achievementCountsByKind.count == AchievementKind.allCases.count
                && achievementCountsByKind.values.allSatisfy { $0 == 40 }
                && Set(descriptors.map(\.id)).count == descriptors.count
                && subjectTotals.allSatisfy {
                    $0.pebbleCount == Expected.completionCount / Self.subjectCount
                }
        }

        private static let subjectCount = 5
    }

    static func run(
        progress: @escaping @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Report {
        let worker = Task.detached(priority: .userInitiated) {
            try compute(progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func compute(
        progress: @escaping @Sendable (Progress) -> Void
    ) throws -> Report {
        let wallStart = Date.now
        var calendar = Calendar(identifier: .gregorian)
        guard let fixtureTimeZone = TimeZone(secondsFromGMT: 9 * 3_600) else {
            throw ScenarioError.invalidCalendarDate
        }
        calendar.timeZone = fixtureTimeZone
        guard let fixtureStart = calendar.date(from: DateComponents(
            year: 1985,
            month: 1,
            day: 1,
            hour: 8
        )),
            let fixtureEnd = calendar.date(
                byAdding: .day,
                value: Expected.dayCount,
                to: fixtureStart
            )
        else {
            throw ScenarioError.invalidCalendarDate
        }

        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        var random = SplitMix64(seed: 0x5453_554D_4942_454E)
        var missesSinceGold = 0
        var accumulator = StreamingRollupAccumulator()
        var subjectCounts: [DebugSubject: Int] = [:]
        var completionCount = 0
        var focusSeconds = 0
        var grams = 0
        var shortBreakCount = 0
        var longBreakCount = 0
        var normalCount = 0
        var goldCount = 0
        var prismCount = 0
        var pityGoldCount = 0

        for dayIndex in 0 ..< Expected.dayCount {
            try Task.checkCancellation()
            guard let dayStart = calendar.date(
                byAdding: .day,
                value: dayIndex,
                to: fixtureStart
            ) else {
                throw ScenarioError.invalidCalendarDate
            }
            var cursor = dayStart

            for slot in 0 ..< Expected.focusSessionsPerDay {
                let globalIndex = dayIndex * Expected.focusSessionsPerDay + slot
                let sessionID = deterministicUUID(
                    index: globalIndex,
                    namespace: 0x5345_5353_494F_4E00
                )
                try engine.startFocus(
                    duration: .twentyFiveMinutes,
                    isPro: false,
                    now: cursor,
                    sessionID: sessionID
                )
                let scheduledEnd = cursor.addingTimeInterval(
                    TimeInterval(Constants.Timer.twentyFiveMinutes * Constants.Timer.secondsPerMinute)
                )
                guard case let .focusCompleted(completion)? = engine.advance(
                    at: scheduledEnd,
                    observedUptime: TimeInterval(globalIndex * 1_800)
                ) else {
                    throw ScenarioError.unexpectedTimerTransition
                }

                let reward = GachaEngine.draw(
                    source: completion.source,
                    completedSeconds: completion.seconds,
                    sinceLastGold: missesSinceGold,
                    unitRoll: random.nextUnitDouble()
                )
                missesSinceGold = reward.sinceLastGold
                switch reward.kind {
                case .normal: normalCount += 1
                case .gold: goldCount += 1
                case .prism: prismCount += 1
                }
                if reward.triggeredPity { pityGoldCount += 1 }

                let subject = subjects[globalIndex % subjects.count]
                subjectCounts[subject, default: 0] += 1
                accumulator.append(Body(
                    id: sessionID,
                    level: 0,
                    pebbleCount: 1,
                    grams: completion.grams,
                    subjectCounts: [subject: 1],
                    periodStart: completion.startedAt,
                    periodEnd: completion.endedAt,
                    goldPebbleCount: reward.kind == .gold ? 1 : 0,
                    prismPebbleCount: reward.kind == .prism ? 1 : 0,
                    kind: reward.kind
                ))

                completionCount += 1
                focusSeconds += completion.seconds
                grams += completion.grams

                try engine.startBreak(now: completion.endedAt)
                let breakSnapshot = engine.snapshot(at: completion.endedAt)
                switch breakSnapshot.phase {
                case .shortBreak: shortBreakCount += 1
                case .longBreak: longBreakCount += 1
                default: throw ScenarioError.unexpectedTimerTransition
                }
                guard let breakEnd = breakSnapshot.endDate,
                      engine.advance(at: breakEnd) == .breakCompleted
                else {
                    throw ScenarioError.unexpectedTimerTransition
                }
                cursor = breakEnd
            }

            let completedDays = dayIndex + 1
            if completedDays.isMultiple(of: 30) || completedDays == Expected.dayCount {
                progress(Progress(
                    completedDays: completedDays,
                    completedSessions: completionCount
                ))
            }
        }

        let achievements = makeAchievements(
            fixtureStart: fixtureStart,
            calendar: calendar
        )
        let wallEnd = Date.now
        let totals = subjectCounts.map {
            SubjectTotal(
                name: $0.key.name,
                colorHex: $0.key.colorHex,
                pebbleCount: $0.value
            )
        }
        .sorted { lhs, rhs in
            if lhs.pebbleCount == rhs.pebbleCount { return lhs.name < rhs.name }
            return lhs.pebbleCount > rhs.pebbleCount
        }

        return Report(
            startedAt: fixtureStart,
            endedAt: fixtureEnd,
            elapsedSeconds: wallEnd.timeIntervalSince(wallStart),
            dayCount: Expected.dayCount,
            completionCount: completionCount,
            focusSeconds: focusSeconds,
            grams: grams,
            shortBreakCount: shortBreakCount,
            longBreakCount: longBreakCount,
            normalCount: normalCount,
            goldCount: goldCount,
            prismCount: prismCount,
            pityGoldCount: pityGoldCount,
            finalMissesSinceGold: missesSinceGold,
            maximumStudyBodyCount: accumulator.maximumBodyCount,
            aggregateCreationCount: accumulator.aggregateCreationCount,
            aggregateCreationsByLevel: accumulator.aggregateCreationsByLevel,
            bodies: accumulator.snapshots,
            achievements: achievements,
            subjectTotals: totals
        )
    }

    private static func makeAchievements(
        fixtureStart: Date,
        calendar: Calendar
    ) -> [AchievementSnapshot] {
        (0 ..< 40).flatMap { yearOffset in
            AchievementKind.allCases.enumerated().map { kindIndex, kind in
                let date = calendar.date(
                    byAdding: .year,
                    value: yearOffset,
                    to: fixtureStart
                ) ?? fixtureStart
                let subject = subjects[(yearOffset + kindIndex) % subjects.count]
                return AchievementSnapshot(
                    id: deterministicUUID(
                        index: yearOffset * AchievementKind.allCases.count + kindIndex,
                        namespace: 0x4143_4849_4556_4500
                    ),
                    kind: kind,
                    subjectName: subject.name,
                    colorHex: subject.colorHex,
                    achievedAt: date.addingTimeInterval(TimeInterval(kindIndex * 60))
                )
            }
        }
    }

    private struct DebugSubject: Hashable, Sendable {
        let name: String
        let colorHex: String
    }

    private static let subjects: [DebugSubject] = [
        DebugSubject(name: "資格", colorHex: "#FF647F"),
        DebugSubject(name: "英語", colorHex: Constants.Color.english),
        DebugSubject(name: "数学", colorHex: Constants.Color.mathematics),
        DebugSubject(name: "仕事", colorHex: "#28C7A0"),
        DebugSubject(name: "研究", colorHex: "#A979FF")
    ]

    private struct Body: Sendable {
        let id: UUID
        let level: Int
        let pebbleCount: Int
        let grams: Int
        let subjectCounts: [DebugSubject: Int]
        let periodStart: Date
        let periodEnd: Date
        let goldPebbleCount: Int
        let prismPebbleCount: Int
        let kind: PebbleKind

        var radius: Double {
            level == 0
                ? Double(Constants.Jar.measuredRadius)
                : StrataMath.aggregateRadius(level: level)
        }

        var snapshot: BodySnapshot {
            let ordered = subjectCounts.sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key.name < rhs.key.name }
                return lhs.value > rhs.value
            }
            let total = max(1, ordered.reduce(0) { $0 + $1.value })
            var accumulated = 0.0
            let colorMix = ordered.enumerated().map { index, value in
                let fraction: Double
                if index == ordered.indices.last {
                    fraction = max(0, 1 - accumulated)
                } else {
                    fraction = Double(value.value) / Double(total)
                    accumulated += fraction
                }
                return StratumColorFraction(hex: value.key.colorHex, fraction: fraction)
            }
            let subjectMix = ordered.map {
                AggregateSubjectFraction(
                    name: $0.key.name,
                    colorHex: $0.key.colorHex,
                    pebbleCount: $0.value
                )
            }
            return BodySnapshot(
                id: id,
                level: level,
                pebbleCount: pebbleCount,
                grams: grams,
                colorMix: colorMix,
                subjectMix: subjectMix,
                periodStart: periodStart,
                periodEnd: periodEnd,
                goldPebbleCount: goldPebbleCount,
                prismPebbleCount: prismPebbleCount,
                kind: kind
            )
        }
    }

    private struct StreamingRollupAccumulator {
        private var bodies: [Body] = []
        private var aggregateOrdinal = 0
        private(set) var maximumBodyCount = 0
        private(set) var aggregateCreationsByLevel: [Int: Int] = [:]

        var aggregateCreationCount: Int {
            aggregateCreationsByLevel.values.reduce(0, +)
        }

        var snapshots: [BodySnapshot] {
            bodies
                .map(\.snapshot)
                .sorted { lhs, rhs in
                    if lhs.periodEnd == rhs.periodEnd { return lhs.id.uuidString < rhs.id.uuidString }
                    return lhs.periodEnd < rhs.periodEnd
                }
        }

        mutating func append(_ body: Body) {
            bodies.append(body)
            maximumBodyCount = max(maximumBodyCount, bodies.count)
            carryCompletedAggregateLevels()
            maximumBodyCount = max(maximumBodyCount, bodies.count)
        }

        private mutating func carryCompletedAggregateLevels() {
            while let level = Set(bodies.map(\.level))
                .sorted()
                .first(where: { candidate in
                    bodies.lazy.filter { $0.level == candidate }.count
                        >= Constants.Jar.aggregateFanIn
                }) {
                guard combineFirstTen(level: level) else { return }
            }
        }

        @discardableResult
        private mutating func combineFirstTen(level: Int) -> Bool {
            var selectedIndices: [Int] = []
            selectedIndices.reserveCapacity(Constants.Jar.aggregateFanIn)
            for index in bodies.indices where bodies[index].level == level {
                selectedIndices.append(index)
                if selectedIndices.count == Constants.Jar.aggregateFanIn { break }
            }
            guard selectedIndices.count == Constants.Jar.aggregateFanIn else { return false }
            let selected = selectedIndices.map { bodies[$0] }
            let selectedSet = Set(selectedIndices)
            aggregateOrdinal += 1
            let outputLevel = level + 1
            var combinedSubjects: [DebugSubject: Int] = [:]
            selected.forEach { body in
                body.subjectCounts.forEach {
                    combinedSubjects[$0.key, default: 0] += $0.value
                }
            }
            let combined = Body(
                id: deterministicUUID(
                    index: aggregateOrdinal,
                    // `aggregateOrdinal` is already globally unique. Mixing
                    // the level into the namespace with XOR could cancel bits
                    // from the ordinal and collide across hierarchy levels.
                    namespace: 0x4147_4752_4547_4154
                ),
                level: outputLevel,
                pebbleCount: selected.reduce(0) { $0 + $1.pebbleCount },
                grams: selected.reduce(0) { $0 + $1.grams },
                subjectCounts: combinedSubjects,
                periodStart: selected.map(\.periodStart).min() ?? .distantPast,
                periodEnd: selected.map(\.periodEnd).max() ?? .distantPast,
                goldPebbleCount: selected.reduce(0) { $0 + $1.goldPebbleCount },
                prismPebbleCount: selected.reduce(0) { $0 + $1.prismPebbleCount },
                kind: .normal
            )
            bodies = bodies.indices
                .filter { !selectedSet.contains($0) }
                .map { bodies[$0] }
            bodies.append(combined)
            aggregateCreationsByLevel[outputLevel, default: 0] += 1
            maximumBodyCount = max(maximumBodyCount, bodies.count)
            return true
        }
    }

    private struct SplitMix64 {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func nextUnitDouble() -> Double {
            Double(next() >> 11) / Double(UInt64(1) << 53)
        }
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

    private enum ScenarioError: Error {
        case invalidCalendarDate
        case unexpectedTimerTransition
    }
}
#endif
