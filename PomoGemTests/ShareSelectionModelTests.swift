import SwiftData
import XCTest
@testable import PomoGem

/// The share composer resolves its card from these rules once per input
/// change (history-10). These tests pin the resolved content and prove the
/// index-based aggregate membership produces the same visuals as the former
/// full scan per root.
@MainActor
final class ShareSelectionModelTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext { container.mainContext }
    private let calendar = Calendar(identifier: .gregorian)

    override func setUpWithError() throws {
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
        container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(
                "ShareSelectionModelTests-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )]
        )
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    func testMeasuredOnlyCardLeavesOutSelfReportedFocusAndNamesTheExactAmount() throws {
        let now = Date.now
        let measured = (0..<3).map { index in
            session(endingAt: now.addingTimeInterval(-Double(10 - index) * 3_600), minutes: 25)
        }
        let manualHour = session(endingAt: now.addingTimeInterval(-5 * 3_600), minutes: 60, source: .manual)
        let manualHalf = session(endingAt: now.addingTimeInterval(-4 * 3_600), minutes: 30, source: .manual)
        let stone = AchievementStone(kind: .examPass, achievedAt: now.addingTimeInterval(-3_600))
        context.insert(stone)
        try context.save()

        var input = makeInput(sessions: measured + [manualHour, manualHalf], achievements: [stone])
        let measuredOnly = ShareSelectionModel.make(input)
        XCTAssertEqual(measuredOnly.sessions.map(\.id), measured.map(\.id))
        XCTAssertEqual(measuredOnly.totalGrams, 750)
        XCTAssertFalse(measuredOnly.includesSelfReportedFocus)
        XCTAssertTrue(measuredOnly.hasExcludedSelfReportedContent)
        XCTAssertEqual(measuredOnly.excludedSelfReportedGrams, 900)
        XCTAssertTrue(measuredOnly.scopeHasSelfReportedSessions)
        XCTAssertEqual(measuredOnly.achievements.map(\.id), [stone.id])
        XCTAssertTrue(measuredOnly.hasShareableContent)

        input.includeManual = true
        let included = ShareSelectionModel.make(input)
        XCTAssertEqual(included.sessions.count, 5)
        XCTAssertEqual(included.totalGrams, 1_650)
        XCTAssertTrue(included.includesSelfReportedFocus)
        XCTAssertFalse(included.hasExcludedSelfReportedContent)
        XCTAssertNil(included.excludedSelfReportedGrams)
    }

    func testOnlySelfReportedFocusAndAStoneStillExplainsTheExcludedTime() throws {
        // walk-std-04: a month holding 1時間 + 30分 of manual focus and one
        // 記念石 used to read as 0g with no way to include the focus.
        let now = Date.now
        let manual = [
            session(endingAt: now.addingTimeInterval(-7_200), minutes: 60, source: .manual),
            session(endingAt: now.addingTimeInterval(-3_600), minutes: 30, source: .manual)
        ]
        let stone = AchievementStone(kind: .examPass, achievedAt: now)
        context.insert(stone)
        try context.save()

        let model = ShareSelectionModel.make(makeInput(sessions: manual, achievements: [stone]))
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertEqual(model.totalGrams, 0)
        XCTAssertTrue(model.hasShareableContent, "The stone alone still makes a card")
        XCTAssertTrue(model.hasExcludedSelfReportedContent)
        XCTAssertEqual(model.excludedSelfReportedGrams, 900)
        XCTAssertEqual(DurationPresentation.focusLabel(grams: model.excludedSelfReportedGrams ?? 0), "1時間30分")
    }

    func testExcludedAmountIsWithheldWhenThePageIsPartial() throws {
        let manual = session(endingAt: .now, minutes: 30, source: .manual)
        try context.save()
        var input = makeInput(sessions: [manual])
        input.historyPageIsPartial = true
        let model = ShareSelectionModel.make(input)
        XCTAssertTrue(model.hasExcludedSelfReportedContent)
        XCTAssertNil(model.excludedSelfReportedGrams)
    }

    func testMonthScopeKeepsOnlyThatMonthsFocusAndStones() throws {
        let september = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 10)))
        let august = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 10)))
        let inMonth = session(endingAt: september, minutes: 25)
        let outside = session(endingAt: august, minutes: 60)
        let septemberStone = AchievementStone(kind: .perfectScore, achievedAt: september)
        let augustStone = AchievementStone(kind: .examPass, achievedAt: august)
        context.insert(septemberStone)
        context.insert(augustStone)
        try context.save()

        var input = makeInput(sessions: [inMonth, outside], achievements: [septemberStone, augustStone])
        input.scope = .month(september)
        let model = ShareSelectionModel.make(input)
        XCTAssertEqual(model.sessions.map(\.id), [inMonth.id])
        XCTAssertEqual(model.totalGrams, 250)
        XCTAssertEqual(model.achievements.map(\.id), [septemberStone.id])
    }

    func testAggregateMembershipLookupMatchesTheFormerFullScanPerRoot() throws {
        let now = Date.now
        let subjects = ["#E85D4A", "#4AA8E8", "#7BD88F"].enumerated().map { index, hex in
            let subject = Subject(name: "テーマ\(index)", colorHex: hex, sortOrder: index)
            context.insert(subject)
            return subject
        }
        let sessions: [StudySession] = (0..<1_000).map { index in
            session(
                endingAt: now.addingTimeInterval(-Double(1_000 - index) * 4 * 3_600),
                minutes: index.isMultiple(of: 4) ? 60 : 25,
                source: index.isMultiple(of: 7) ? .manual : .timer,
                subject: subjects[index % subjects.count]
            )
        }
        var roots: [AggregatePebble] = []
        for rootIndex in 0..<8 {
            let members = Array(sessions[(rootIndex * 10)..<(rootIndex * 10 + 10)])
            let manualCount = members.filter { $0.effectiveSource.isSelfReported }.count
            let root = AggregatePebble(
                createdAt: members.last!.endAt,
                level: 1,
                pebbleCount: 10,
                grams: members.map(\.grams).reduce(0, +),
                measuredPebbleCount: 10 - manualCount,
                manualPebbleCount: manualCount,
                colorMixJSON: "[]",
                periodStart: members.first!.startAt,
                periodEnd: members.last!.endAt,
                sessionIDs: members.map(\.id)
            )
            context.insert(root)
            roots.append(root)
        }
        try context.save()

        for includeManual in [false, true] {
            var input = makeInput(sessions: sessions, aggregates: roots)
            input.includeManual = includeManual
            let startedAt = ContinuousClock.now
            let model = ShareSelectionModel.make(input)
            print("SHARE_SELECTION includeManual=\(includeManual) build=\(startedAt.duration(to: .now))")

            let unique = StudySessionSyncPolicy.canonicalSessions(from: sessions)
                .sorted { $0.endAt < $1.endAt }
            let selected = includeManual ? unique : unique.filter { $0.effectiveSource.isMeasured }
            let reference = AggregatePebblePolicy.disjointRootSummaries(from: roots)
                .compactMap { root -> ShareAggregateVisual? in
                    let resolved = AggregatePebblePolicy.descendantSessionIDs(of: root, in: roots)
                    let membership = Set(resolved)
                    return ShareAggregateVisual(
                        reconstructing: root,
                        resolvedSessionIDs: resolved,
                        allMemberSessions: unique.filter { membership.contains($0.id) },
                        includedMemberSessions: selected.filter { membership.contains($0.id) }
                    )
                }
                .sorted { $0.createdAt < $1.createdAt }

            XCTAssertEqual(model.aggregates.count, 8)
            XCTAssertEqual(model.aggregates, reference)
            XCTAssertEqual(model.sessions.map(\.id), selected.map(\.id))
            XCTAssertEqual(
                model.totalGrams,
                NonnegativeIntPolicy.sum(selected.map(\.grams)),
                "Membership-backed aggregates index the sessions; they add no mass"
            )
            XCTAssertEqual(model.includesSelfReportedFocus, includeManual)
            XCTAssertEqual(model.hasExcludedSelfReportedContent, !includeManual)
        }
    }

    func testUnverifiedAggregateCacheIsIgnored() throws {
        let members = (0..<10).map { index in
            session(endingAt: Date.now.addingTimeInterval(-Double(20 - index) * 3_600), minutes: 25)
        }
        let root = AggregatePebble(
            createdAt: members.last!.endAt,
            level: 1,
            pebbleCount: 10,
            grams: 2_500,
            measuredPebbleCount: 10,
            colorMixJSON: "[]",
            periodStart: members.first!.startAt,
            periodEnd: members.last!.endAt,
            sessionIDs: members.map(\.id)
        )
        context.insert(root)
        try context.save()

        var input = makeInput(sessions: members, aggregates: [root])
        XCTAssertEqual(ShareSelectionModel.make(input).aggregates.map(\.id), [root.id])
        input.acceptsVerifiedAggregateCache = false
        let untrusted = ShareSelectionModel.make(input)
        XCTAssertTrue(untrusted.aggregates.isEmpty)
        XCTAssertEqual(untrusted.totalGrams, 2_500)
    }

    func testScopedCrystalIsTheAuthoritativeSummaryWhenNothingIsFilteredOut() throws {
        let members = (0..<10).map { index in
            session(
                endingAt: Date.now.addingTimeInterval(-Double(20 - index) * 3_600),
                minutes: 25,
                source: index == 0 ? .manual : .timer
            )
        }
        let root = AggregatePebble(
            createdAt: members.last!.endAt,
            level: 1,
            pebbleCount: 10,
            grams: 2_500,
            measuredPebbleCount: 9,
            manualPebbleCount: 1,
            colorMixJSON: "[]",
            periodStart: members.first!.startAt,
            periodEnd: members.last!.endAt,
            sessionIDs: members.map(\.id)
        )
        context.insert(root)
        try context.save()

        var input = makeInput(sessions: members, aggregates: [root])
        input.scope = .aggregate(id: root.id, monthLabel: "2026年9月")
        input.includeManual = true
        let summary = ShareSelectionModel.make(input)
        XCTAssertTrue(summary.sessions.isEmpty, "The summary owns the mass; members are not added again")
        XCTAssertEqual(summary.aggregates.map(\.id), [root.id])
        XCTAssertEqual(summary.totalGrams, 2_500)
        XCTAssertTrue(summary.includesSelfReportedFocus)

        input.includeManual = false
        let measuredOnly = ShareSelectionModel.make(input)
        XCTAssertEqual(measuredOnly.sessions.count, 9)
        XCTAssertEqual(measuredOnly.totalGrams, 2_250)
        XCTAssertEqual(measuredOnly.aggregates.first?.pebbleCount, 9)
        XCTAssertTrue(measuredOnly.scopedAggregateHasSelfReportedPebbles)
        XCTAssertFalse(measuredOnly.includesSelfReportedFocus)
        XCTAssertNil(
            measuredOnly.excludedSelfReportedGrams,
            "Self-reported time inside a crystal is not named as an exact amount"
        )
    }

    // MARK: - Branches that decide mass and the 自己申告 disclosure

    func testCompactLifetimeRootsCarryTheMassWhenOnlyTheNewestRecordsAreLoaded() throws {
        // A long history loads only its newest page; measured-only roots
        // stand for everything older without expanding it.
        let now = Date.now
        let roots: [AggregatePebble] = (0..<2).map { index in
            root(
                createdAt: now.addingTimeInterval(-Double(40 - index) * 86_400),
                members: (0..<10).map { _ -> UUID in UUID() },
                grams: 2_500,
                measured: 10
            )
        }
        let loose: [StudySession] = (0..<3).map { index in
            session(endingAt: now.addingTimeInterval(-Double(3 - index) * 3_600), minutes: 25)
        }
        try context.save()

        var input = makeInput(sessions: loose, aggregates: roots)
        input.historyPageIsPartial = true
        input.allSessionRowCount = 23
        let complete = ShareSelectionModel.make(input)
        XCTAssertTrue(complete.usesCompactRootProjection)
        XCTAssertFalse(complete.compactProjectionIsIncomplete)
        XCTAssertEqual(complete.sessions.map(\.id), loose.map(\.id))
        XCTAssertEqual(Set(complete.aggregates.map(\.id)), Set(roots.map(\.id)))
        XCTAssertTrue(complete.aggregates.allSatisfy(\.contributesStandaloneTotals))
        XCTAssertEqual(complete.totalGrams, 2 * 2_500 + 3 * 250)
        XCTAssertFalse(complete.includesSelfReportedFocus)
        XCTAssertFalse(complete.hasExcludedSelfReportedContent)
        XCTAssertNil(complete.excludedSelfReportedGrams)

        // Rows the roots and the loose page do not account for (or a
        // duplicate) make the card say 読み込み分 instead of lifetime.
        input.allSessionRowCount = 25
        XCTAssertTrue(ShareSelectionModel.make(input).compactProjectionIsIncomplete)
        input.allSessionRowCount = 23
        input.loosePageIsPartial = true
        XCTAssertTrue(ShareSelectionModel.make(input).compactProjectionIsIncomplete)
        input.loosePageIsPartial = false

        // A loose record the local projection already represents is not
        // added again on top of its root.
        input.localRepresentedSessionIDs = [loose[0].id]
        input.allSessionRowCount = 22
        let represented = ShareSelectionModel.make(input)
        XCTAssertEqual(represented.sessions.map(\.id), Array(loose.dropFirst()).map(\.id))
        XCTAssertEqual(represented.totalGrams, 2 * 2_500 + 2 * 250)
        XCTAssertFalse(represented.compactProjectionIsIncomplete)
    }

    func testSelfReportedLooseRecordKeepsAMeasuredOnlyCardOffCompactRoots() throws {
        let now = Date.now
        let roots = [root(
            createdAt: now.addingTimeInterval(-40 * 86_400),
            members: (0..<10).map { _ -> UUID in UUID() },
            grams: 2_500,
            measured: 10
        )]
        let measured = session(endingAt: now.addingTimeInterval(-7_200), minutes: 25)
        let manual = session(endingAt: now.addingTimeInterval(-3_600), minutes: 30, source: .manual)
        try context.save()

        var input = makeInput(sessions: [measured, manual], aggregates: roots)
        input.historyPageIsPartial = true
        input.allSessionRowCount = 12
        let measuredOnly = ShareSelectionModel.make(input)
        XCTAssertFalse(
            measuredOnly.usesCompactRootProjection,
            "Roots cannot prove no self-reported time hides behind them here"
        )
        XCTAssertFalse(measuredOnly.compactProjectionIsIncomplete)
        XCTAssertEqual(measuredOnly.sessions.map(\.id), [measured.id])
        XCTAssertTrue(measuredOnly.aggregates.isEmpty, "Unloaded members cannot be reconstructed")
        XCTAssertEqual(measuredOnly.totalGrams, 250)
        XCTAssertTrue(measuredOnly.hasExcludedSelfReportedContent)
        XCTAssertNil(measuredOnly.excludedSelfReportedGrams, "A partial page cannot name an exact amount")

        input.includeManual = true
        let included = ShareSelectionModel.make(input)
        XCTAssertTrue(included.usesCompactRootProjection)
        XCTAssertEqual(included.totalGrams, 2_500 + 250 + 300)
        XCTAssertTrue(included.includesSelfReportedFocus)
        XCTAssertFalse(included.hasExcludedSelfReportedContent)
    }

    func testLegacyStratumWithMembershipIsRebuiltFromItsMeasuredMembers() throws {
        let now = Date.now
        let members: [StudySession] = (0..<10).map { index in
            let isManual = index < 2
            return session(
                endingAt: now.addingTimeInterval(-Double(20 - index) * 3_600),
                minutes: isManual ? 60 : 25,
                source: isManual ? SessionSource.manual : SessionSource.timer
            )
        }
        let layer = Stratum(
            bakedAt: members.last!.endAt,
            pebbleCount: 10,
            heightPt: 10,
            colorMixJSON: "[]",
            monthLabel: "2026年9月",
            grams: 3_200,
            sessionIDs: members.map(\.id)
        )
        context.insert(layer)
        try context.save()

        var input = makeInput(sessions: members, strata: [layer])
        let measuredOnly = ShareSelectionModel.make(input)
        XCTAssertEqual(measuredOnly.aggregates.map(\.id), [layer.id])
        XCTAssertEqual(measuredOnly.aggregates.first?.pebbleCount, 8)
        XCTAssertFalse(measuredOnly.aggregates.first?.contributesStandaloneTotals ?? true)
        XCTAssertEqual(measuredOnly.totalGrams, 8 * 250, "The layer indexes its members; it adds no mass")
        XCTAssertFalse(measuredOnly.includesSelfReportedFocus)
        XCTAssertTrue(measuredOnly.hasExcludedSelfReportedContent)
        XCTAssertEqual(measuredOnly.excludedSelfReportedGrams, 1_200, "Known members name an exact amount")

        input.includeManual = true
        let included = ShareSelectionModel.make(input)
        XCTAssertEqual(included.aggregates.first?.pebbleCount, 10)
        XCTAssertEqual(included.totalGrams, 3_200)
        XCTAssertTrue(included.includesSelfReportedFocus)
        XCTAssertFalse(included.hasExcludedSelfReportedContent)
    }

    func testLegacyStratumWithoutMembershipIsOnlySharedAsSelfReported() throws {
        let measured = session(endingAt: .now, minutes: 25)
        let layer = Stratum(
            bakedAt: Date.now.addingTimeInterval(-90 * 86_400),
            pebbleCount: 10,
            heightPt: 10,
            colorMixJSON: "[]",
            monthLabel: "2026年6月",
            grams: 2_500
        )
        context.insert(layer)
        try context.save()

        var input = makeInput(sessions: [measured], strata: [layer])
        let measuredOnly = ShareSelectionModel.make(input)
        XCTAssertTrue(measuredOnly.aggregates.isEmpty, "Its mix is unknown, so a measured-only card leaves it out")
        XCTAssertEqual(measuredOnly.totalGrams, 250)
        XCTAssertFalse(measuredOnly.includesSelfReportedFocus)
        XCTAssertTrue(measuredOnly.hasExcludedSelfReportedContent)
        XCTAssertNil(measuredOnly.excludedSelfReportedGrams)

        input.includeManual = true
        let included = ShareSelectionModel.make(input)
        XCTAssertEqual(included.aggregates.map(\.id), [layer.id])
        XCTAssertEqual(included.totalGrams, 2_750, "A membership-less layer carries its own mass")
        XCTAssertTrue(included.includesSelfReportedFocus, "Unknown composition is disclosed as self-reported")
        XCTAssertFalse(included.hasExcludedSelfReportedContent)
    }

    func testUnattributedCompatibilityAggregateFollowsItsKnownComposition() throws {
        let measured = session(endingAt: .now, minutes: 25)
        let unknownMix = root(
            createdAt: Date.now.addingTimeInterval(-60 * 86_400),
            members: [],
            grams: 2_500,
            measured: 0
        )
        let allMeasured = root(
            createdAt: Date.now.addingTimeInterval(-30 * 86_400),
            members: [],
            grams: 2_500,
            measured: 10
        )
        try context.save()

        var input = makeInput(sessions: [measured], aggregates: [unknownMix])
        let unknownOff = ShareSelectionModel.make(input)
        XCTAssertTrue(unknownOff.aggregates.isEmpty)
        XCTAssertEqual(unknownOff.totalGrams, 250)
        XCTAssertFalse(unknownOff.includesSelfReportedFocus)
        XCTAssertTrue(unknownOff.hasExcludedSelfReportedContent)
        XCTAssertNil(unknownOff.excludedSelfReportedGrams)

        input.includeManual = true
        let unknownOn = ShareSelectionModel.make(input)
        XCTAssertEqual(unknownOn.aggregates.map(\.id), [unknownMix.id])
        XCTAssertEqual(unknownOn.totalGrams, 2_750)
        XCTAssertTrue(unknownOn.includesSelfReportedFocus, "Unknown composition is disclosed as self-reported")
        XCTAssertFalse(unknownOn.hasExcludedSelfReportedContent)

        input = makeInput(sessions: [measured], aggregates: [allMeasured])
        let measuredOff = ShareSelectionModel.make(input)
        XCTAssertEqual(measuredOff.aggregates.map(\.id), [allMeasured.id])
        XCTAssertEqual(measuredOff.totalGrams, 2_750)
        XCTAssertFalse(measuredOff.includesSelfReportedFocus)
        XCTAssertFalse(
            measuredOff.hasExcludedSelfReportedContent,
            "An all-measured summary stays on the card, so nothing was left out"
        )
        input.includeManual = true
        let measuredOn = ShareSelectionModel.make(input)
        XCTAssertEqual(measuredOn.totalGrams, 2_750)
        XCTAssertTrue(measuredOn.includesSelfReportedFocus, "Its composition is still not attributed")
    }

    func testMonthScopeTakesOnlyThatMonthsPartOfARootSpanningTwoMonths() throws {
        let august = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 10)))
        let september = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 10)))
        let augustMembers: [StudySession] = (0..<5).map { index in
            session(endingAt: august.addingTimeInterval(Double(index) * 3_600), minutes: 25)
        }
        let septemberMembers: [StudySession] = (0..<5).map { index in
            let isManual = index == 0
            return session(
                endingAt: september.addingTimeInterval(Double(index) * 3_600),
                minutes: isManual ? 60 : 25,
                source: isManual ? SessionSource.manual : SessionSource.timer
            )
        }
        let members = augustMembers + septemberMembers
        let spanning = AggregatePebble(
            createdAt: septemberMembers.last!.endAt,
            level: 1,
            pebbleCount: 10,
            grams: NonnegativeIntPolicy.sum(members.map(\.grams)),
            measuredPebbleCount: 9,
            manualPebbleCount: 1,
            colorMixJSON: "[]",
            periodStart: augustMembers.first!.startAt,
            periodEnd: septemberMembers.last!.endAt,
            sessionIDs: members.map(\.id)
        )
        context.insert(spanning)
        try context.save()

        var input = makeInput(sessions: members, aggregates: [spanning])
        input.scope = .month(september)
        let measuredOnly = ShareSelectionModel.make(input)
        XCTAssertEqual(measuredOnly.sessions.map(\.id), Array(septemberMembers.dropFirst()).map(\.id))
        XCTAssertEqual(measuredOnly.aggregates.map(\.id), [spanning.id])
        XCTAssertEqual(measuredOnly.aggregates.first?.pebbleCount, 4, "Only September's measured members")
        XCTAssertEqual(measuredOnly.aggregates.first?.grams, 4 * 250)
        XCTAssertEqual(measuredOnly.totalGrams, 4 * 250, "August's half of the root is not September's mass")
        XCTAssertFalse(measuredOnly.includesSelfReportedFocus)
        XCTAssertTrue(measuredOnly.hasExcludedSelfReportedContent)
        XCTAssertTrue(measuredOnly.scopedAggregateHasSelfReportedPebbles)
        XCTAssertNil(
            measuredOnly.excludedSelfReportedGrams,
            "Self-reported time inside a crystal is not named as an exact amount"
        )

        input.includeManual = true
        let included = ShareSelectionModel.make(input)
        XCTAssertEqual(included.aggregates.first?.pebbleCount, 5)
        XCTAssertEqual(included.totalGrams, 600 + 4 * 250)
        XCTAssertTrue(included.includesSelfReportedFocus)
        XCTAssertFalse(included.hasExcludedSelfReportedContent)
    }

    func testCacheReusesTheSelectionUntilAnInputChanges() {
        let cache = ShareSelectionCache()
        var builds = 0
        func read(_ key: ShareSelectionInput.Key) {
            _ = cache.model(for: key) {
                builds += 1
                return .empty
            }
        }
        let base = key(generation: 1, includeManual: false)
        read(base)
        read(base)
        read(base)
        XCTAssertEqual(builds, 1, "Unrelated body passes (typing, chips, format) reuse the selection")
        read(key(generation: 1, includeManual: true))
        XCTAssertEqual(builds, 2)
        read(key(generation: 2, includeManual: true))
        XCTAssertEqual(builds, 3, "A new load or invalidation rebuilds it")
        read(key(generation: 2, includeManual: true, acceptsCache: false))
        XCTAssertEqual(builds, 4, "Losing aggregate trust rebuilds it")
        read(key(generation: 2, includeManual: true, acceptsCache: false))
        XCTAssertEqual(builds, 4)
    }

    // MARK: - Fixtures

    private func key(
        generation: Int,
        includeManual: Bool,
        acceptsCache: Bool = true
    ) -> ShareSelectionInput.Key {
        ShareSelectionInput.Key(
            recordsGeneration: generation,
            scope: .all,
            includeManual: includeManual,
            resetSnapshots: [],
            allowsAggregateSummaries: true,
            acceptsVerifiedAggregateCache: acceptsCache
        )
    }

    private func session(
        endingAt end: Date,
        minutes: Int,
        source: SessionSource = .timer,
        subject: Subject? = nil
    ) -> StudySession {
        let start = end.addingTimeInterval(-Double(minutes) * 60)
        let value = StudySession(
            subject: subject,
            startAt: start,
            endAt: end,
            seconds: minutes * 60,
            source: source,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: start)
        )
        context.insert(value)
        return value
    }

    /// A level-one root whose members may not be loaded, or, with no
    /// members, a membership-less compatibility summary.
    private func root(
        createdAt: Date,
        members: [UUID],
        grams: Int,
        measured: Int,
        manual: Int = 0
    ) -> AggregatePebble {
        let value = AggregatePebble(
            createdAt: createdAt,
            level: 1,
            pebbleCount: 10,
            grams: grams,
            measuredPebbleCount: measured,
            manualPebbleCount: manual,
            colorMixJSON: "[]",
            periodStart: createdAt.addingTimeInterval(-86_400),
            periodEnd: createdAt,
            sessionIDs: members
        )
        context.insert(value)
        return value
    }

    private func makeInput(
        sessions: [StudySession],
        achievements: [AchievementStone] = [],
        aggregates: [AggregatePebble] = [],
        strata: [Stratum] = []
    ) -> ShareSelectionInput {
        ShareSelectionInput(
            scope: .all,
            includeManual: false,
            resetSnapshots: [],
            allowsAggregateSummaries: true,
            acceptsVerifiedAggregateCache: true,
            storedSessions: sessions,
            looseSessions: sessions,
            storedAchievementStones: achievements,
            storedAggregatePebbles: aggregates,
            storedStrata: strata,
            acceptedAggregateRootIDs: Set(aggregates.map(\.id)),
            localRepresentedSessionIDs: [],
            historyPageIsPartial: false,
            loosePageIsPartial: false,
            aggregatePageIsPartial: false,
            aggregateValidationIsIncomplete: false,
            allSessionRowCount: sessions.count
        )
    }
}
