import Foundation

/// A read-only, deterministic preview of how a repeated study plan would be
/// represented by the current decimal roll-up hierarchy.
///
/// This type deliberately has no persistence dependency. It never opens a
/// ModelContainer, reads the user's subjects, performs a reward draw, or writes
/// a widget snapshot. The returned descriptors exist only long enough to draw
/// the planning sheet.
struct AccumulationPlanProjection: Equatable, Sendable {
    struct Plan: Equatable, Sendable {
        static let yearRange = 1 ... 40
        static let sessionsPerWeekRange = 1 ... 168
        static let minutesPerSessionRange =
            Constants.Timer.customMinimumMinutes ... Constants.Timer.customMaximumMinutes

        let years: Int
        let sessionsPerWeek: Int
        let minutesPerSession: Int

        init(years: Int, sessionsPerWeek: Int, minutesPerSession: Int) {
            self.years = min(max(years, Self.yearRange.lowerBound), Self.yearRange.upperBound)
            self.sessionsPerWeek = min(
                max(sessionsPerWeek, Self.sessionsPerWeekRange.lowerBound),
                Self.sessionsPerWeekRange.upperBound
            )
            self.minutesPerSession = min(
                max(minutesPerSession, Self.minutesPerSessionRange.lowerBound),
                Self.minutesPerSessionRange.upperBound
            )
        }

        /// A humane product-facing starting point. The separate QA-only fixture
        /// still exercises the much heavier 24-completions-per-day boundary.
        static let suggested = Plan(
            years: 40,
            sessionsPerWeek: 7,
            minutesPerSession: Constants.Timer.twentyFiveMinutes
        )

        /// The former forty-year QA fixture expressed through the same pure
        /// projection model. This is useful for regression tests, not the
        /// product-facing default.
        static let fortyYearDemonstration = Plan(
            years: 40,
            sessionsPerWeek: 168,
            minutesPerSession: Constants.Timer.twentyFiveMinutes
        )
    }

    struct Body: Identifiable, Equatable, Sendable {
        let id: UUID
        let level: Int
        let pebbleCount: Int
        let grams: Int
        let periodStart: Date
        let periodEnd: Date

        var isAggregate: Bool { level > 0 }

        var descriptor: PebbleDescriptor {
            if isAggregate {
                let metadata = AggregateMetadata(
                    level: level,
                    pebbleCount: pebbleCount,
                    childAggregateCount: level > 1 ? Constants.Jar.aggregateFanIn : 0,
                    colorMix: Self.sampleColorMix,
                    subjectMix: Self.sampleSubjectMix(pebbleCount: pebbleCount),
                    periodStart: periodStart,
                    periodEnd: periodEnd,
                    sessionIDs: [],
                    measuredPebbleCount: pebbleCount,
                    manualPebbleCount: 0,
                    goldPebbleCount: 0,
                    prismPebbleCount: 0
                )
                return PebbleDescriptor(
                    id: id,
                    subjectName: Self.sampleSubjectName,
                    colorHex: Self.sampleColorHex,
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
                subjectName: Self.sampleSubjectName,
                colorHex: Self.sampleColorHex,
                source: .timer,
                kind: .normal,
                grams: grams,
                createdAt: periodEnd
            )
        }

        private static let sampleSubjectName = "計画上の集中"
        private static let sampleColorHex = Constants.Color.auroraWarm
        private static let sampleColorMix = [
            StratumColorFraction(hex: sampleColorHex, fraction: 1)
        ]

        private static func sampleSubjectMix(pebbleCount: Int) -> [AggregateSubjectFraction] {
            [AggregateSubjectFraction(
                name: sampleSubjectName,
                colorHex: sampleColorHex,
                pebbleCount: pebbleCount
            )]
        }
    }

    let plan: Plan
    let elapsedMonths: Int
    let completionCount: Int
    let focusMinutes: Int
    let grams: Int
    let aggregateCreationCount: Int
    let bodies: [Body]

    var focusHours: Double { Double(focusMinutes) / 60 }
    var studyBodyCount: Int { bodies.count }
    var aggregateBodyCount: Int { bodies.lazy.filter(\.isAggregate).count }
    var representedPebbleCount: Int { bodies.reduce(0) { $0 + $1.pebbleCount } }
    var representedGrams: Int { bodies.reduce(0) { $0 + $1.grams } }
    var bodiesByLevel: [Int: Int] {
        Dictionary(grouping: bodies, by: \.level).mapValues(\.count)
    }
    var descriptors: [PebbleDescriptor] { bodies.map(\.descriptor) }
    var constellationNodes: [EffortConstellationNode] {
        bodies.filter(\.isAggregate).map { body in
            EffortConstellationNode(
                id: body.id,
                level: body.level,
                pebbleCount: body.pebbleCount,
                grams: body.grams,
                colorHex: Constants.Color.auroraWarm,
                colorMix: [StratumColorFraction(
                    hex: Constants.Color.auroraWarm,
                    fraction: 1
                )],
                periodEnd: body.periodEnd,
                containsRare: false
            )
        }
    }

    /// A compact self-check used by the UI and unit tests. It validates the
    /// projection itself, not any persisted user history.
    var isInternallyConsistent: Bool {
        let expectedTotals = Self.projectedTotals(
            plan: plan,
            elapsedMonths: elapsedMonths
        )
        return completionCount >= 0
            && elapsedMonths >= 0
            && elapsedMonths <= plan.years * 12
            // Session count is a separately rounded presentation estimate.
            // Time must come from the unrounded weekly plan so equivalent
            // weekly minutes stay equivalent across session segmentations.
            && completionCount == expectedTotals.completionCount
            && focusMinutes == expectedTotals.focusMinutes
            && grams == focusMinutes * Constants.Mass.gramsPerMinute
            && representedPebbleCount == completionCount
            && representedGrams == grams
            && studyBodyCount <= Constants.Jar.maxPhysicsBodies
            && Set(bodies.map(\.id)).count == bodies.count
    }

    static func make(plan: Plan, elapsedMonths: Int? = nil) -> AccumulationPlanProjection {
        let boundedElapsedMonths = min(
            max(elapsedMonths ?? plan.years * 12, 0),
            plan.years * 12
        )
        // Session count and total time intentionally round independently.
        // Multiplying an already-rounded session count by its duration makes
        // equivalent plans diverge (for example, 6 x 10 minutes/week versus
        // 1 x 60 minutes/week). `projectedTotals` retains the exact rational
        // expectation until the final display-minute boundary.
        let totals = projectedTotals(
            plan: plan,
            elapsedMonths: boundedElapsedMonths
        )
        let elapsedYears = Double(boundedElapsedMonths) / 12
        let completionCount = totals.completionCount
        let focusMinutes = totals.focusMinutes
        let grams = focusMinutes * Constants.Mass.gramsPerMinute

        let specifications = decimalFrontierSpecifications(
            completionCount: completionCount,
            totalGrams: grams
        )
        let periodStart = Date(timeIntervalSinceReferenceDate: 0)
        let periodDuration = elapsedYears * 365.25 * 24 * 60 * 60
        let bodies = specifications.enumerated().map { index, specification in
            let fraction = Double(index + 1) / Double(max(1, specifications.count))
            return Body(
                id: deterministicUUID(
                    ordinal: index,
                    plan: plan,
                    level: specification.level
                ),
                level: specification.level,
                pebbleCount: specification.pebbleCount,
                grams: specification.grams,
                periodStart: periodStart,
                periodEnd: periodStart.addingTimeInterval(periodDuration * fraction)
            )
        }

        return AccumulationPlanProjection(
            plan: plan,
            elapsedMonths: boundedElapsedMonths,
            completionCount: completionCount,
            focusMinutes: focusMinutes,
            grams: grams,
            aggregateCreationCount: decimalAggregateCreationCount(
                completionCount: completionCount
            ),
            bodies: bodies
        )
    }

    private struct BodySpecification {
        let level: Int
        let pebbleCount: Int
        let grams: Int
    }

    private struct ProjectedTotals {
        let completionCount: Int
        let focusMinutes: Int
    }

    /// Returns display-ready integer estimates while retaining the exact
    /// average-calendar fraction until each metric's final rounding step.
    ///
    /// 365.25 days is exactly 1,461 / 4 days, so elapsed weeks are
    /// `months * 1,461 / 336`. Using this rational form avoids floating-point
    /// drift and guarantees that plans with the same weekly minute product
    /// receive exactly the same projected total minutes and mass.
    private static func projectedTotals(
        plan: Plan,
        elapsedMonths: Int
    ) -> ProjectedTotals {
        let elapsedWeekNumerator = Int64(elapsedMonths) * 1_461
        let elapsedWeekDenominator: Int64 = 12 * 4 * 7

        let completionNumerator = elapsedWeekNumerator
            * Int64(plan.sessionsPerWeek)
        let weeklyMinutes = Int64(plan.sessionsPerWeek)
            * Int64(plan.minutesPerSession)
        let focusMinuteNumerator = elapsedWeekNumerator * weeklyMinutes

        return ProjectedTotals(
            completionCount: roundedNonnegativeQuotient(
                numerator: completionNumerator,
                denominator: elapsedWeekDenominator
            ),
            focusMinutes: roundedNonnegativeQuotient(
                numerator: focusMinuteNumerator,
                denominator: elapsedWeekDenominator
            )
        )
    }

    private static func roundedNonnegativeQuotient(
        numerator: Int64,
        denominator: Int64
    ) -> Int {
        precondition(numerator >= 0 && denominator > 0)
        return Int((numerator + denominator / 2) / denominator)
    }

    /// The final decimal frontier is simply the base-ten digits of the total.
    /// For example, 350,640 completions become 4 ×10, 6 ×100, 5 ×10,000,
    /// and 3 ×100,000 bodies. This is mathematically identical to repeatedly
    /// carrying ten equal-level bodies, but avoids hundreds of thousands of
    /// allocations in a user-facing planning sheet.
    private static func decimalFrontierSpecifications(
        completionCount: Int,
        totalGrams: Int
    ) -> [BodySpecification] {
        var remaining = completionCount
        var magnitude = 1
        var level = 0
        var countSpecifications: [(level: Int, pebbleCount: Int)] = []

        while remaining > 0 {
            let digit = remaining % Constants.Jar.aggregateFanIn
            for _ in 0 ..< digit {
                countSpecifications.append((
                    level: level,
                    pebbleCount: magnitude
                ))
            }
            remaining /= Constants.Jar.aggregateFanIn
            magnitude *= Constants.Jar.aggregateFanIn
            level += 1
        }

        guard completionCount > 0 else { return [] }

        // Count describes the estimated session rhythm; grams describe the
        // independently rounded time expectation. Allocate the latter across
        // the count hierarchy without losing a single gram. This keeps the
        // simulated physical frontier exact even when the rounded session
        // count times one session's duration differs by a few minutes.
        let baseGramsPerPebble = totalGrams / completionCount
        var extraGramCount = totalGrams % completionCount
        return countSpecifications.map { specification in
            let allocatedExtras = min(extraGramCount, specification.pebbleCount)
            extraGramCount -= allocatedExtras
            return BodySpecification(
                level: specification.level,
                pebbleCount: specification.pebbleCount,
                grams: specification.pebbleCount * baseGramsPerPebble
                    + allocatedExtras
            )
        }
    }

    private static func decimalAggregateCreationCount(completionCount: Int) -> Int {
        var sourceCount = completionCount
        var total = 0
        while sourceCount >= Constants.Jar.aggregateFanIn {
            sourceCount /= Constants.Jar.aggregateFanIn
            total += sourceCount
        }
        return total
    }

    private static func deterministicUUID(
        ordinal: Int,
        plan: Plan,
        level: Int
    ) -> UUID {
        var state = UInt64(ordinal + 1)
        state ^= UInt64(plan.years) << 48
        state ^= UInt64(plan.sessionsPerWeek) << 40
        state ^= UInt64(plan.minutesPerSession) << 32
        state ^= UInt64(level) << 24
        let high = mixed(state ^ 0x504C_414E_4E45_4400)
        let low = mixed(state &+ 0x9E37_79B9_7F4A_7C15)
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: high >> 56),
            UInt8(truncatingIfNeeded: high >> 48),
            UInt8(truncatingIfNeeded: high >> 40),
            UInt8(truncatingIfNeeded: high >> 32),
            UInt8(truncatingIfNeeded: high >> 24),
            UInt8(truncatingIfNeeded: high >> 16),
            (UInt8(truncatingIfNeeded: high >> 8) & 0x0F) | 0x40,
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
}

/// Today's jar, the plan's starting point (home-07). Home passes the total it
/// already shows; the plan only adds to it and never writes it anywhere.
struct AccumulationPlanStart: Equatable, Sendable {
    enum Certainty: Equatable, Sendable {
        /// Home's total is complete.
        case exact
        /// Home is still folding older records into its totals, so the jar
        /// holds at least `grams`. Home marks the same total with 「+」.
        case atLeast
        /// iCloud is re-counting the jar and Home shows 「再集計中」 instead
        /// of a mass. The plan shows none either and starts from zero.
        case recounting
    }

    let grams: Int
    let certainty: Certainty

    init(grams: Int, certainty: Certainty) {
        self.grams = certainty == .recounting ? 0 : max(0, grams)
        self.certainty = certainty
    }

    static let empty = AccumulationPlanStart(grams: 0, certainty: .exact)

    /// Today's jar plus what the plan adds, saturating instead of trapping.
    func jarGrams(adding planGrams: Int) -> Int {
        let (sum, overflow) = grams.addingReportingOverflow(max(0, planGrams))
        return overflow ? Int.max : sum
    }
}
