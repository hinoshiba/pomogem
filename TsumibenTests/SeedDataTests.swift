import SwiftData
import XCTest
@testable import Tsumiben

@MainActor
final class SeedDataTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
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
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func testBootstrapIsIdempotentAndDoesNotRestoreDeletedPreset() throws {
        let container = try makeContainer()
        let context = container.mainContext

        try SeedData.bootstrap(context: context)
        try SeedData.bootstrap(context: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Subject>()).count, 5)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Prefs>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<GachaState>()).count, 1)

        let english = try XCTUnwrap(
            context.fetch(FetchDescriptor<Subject>()).first { $0.name == "英語" }
        )
        context.delete(english)
        try context.save()
        try SeedData.bootstrap(context: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Subject>()).count, 4)
        XCTAssertFalse(try context.fetch(FetchDescriptor<Subject>()).contains { $0.name == "英語" })
    }

    func testBootstrapReconcilesCloudDuplicatesWithoutLosingMass() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)

        let duplicatePrefs = Prefs(
            manualDayKey: FairnessPolicy.deviceDayKey(for: .now),
            manualUsedToday: 2,
            soundOn: false,
            hasEverImportedBedrock: true
        )
        context.insert(duplicatePrefs)
        context.insert(GachaState(
            sinceLastGold: 9,
            rewardCreditGrams: 600
        ))
        context.insert(Bedrock(hours: 40))
        context.insert(Bedrock(hours: 120))

        let sessionID = UUID()
        let end = Date.now
        context.insert(StudySession(
            id: sessionID,
            startAt: end.addingTimeInterval(-3_600),
            endAt: end,
            seconds: 3_600,
            source: .timer,
            grams: 600,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: end),
            rareRewardRuleVersion: Constants.Gacha.creditRuleVersion,
            rareRewardParticipated: true,
            rareRewardCreditedGrams: 600,
            rareRewardOutcomesRawValue: RareRewardOutcomeCodec.encode([.gold, .prism])
        ))
        context.insert(StudySession(
            id: sessionID,
            startAt: end.addingTimeInterval(-3_600),
            endAt: end,
            seconds: 3_600,
            source: .timer,
            grams: 600,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: end),
            isBaked: true,
            rareRewardRuleVersion: Constants.Gacha.creditRuleVersion,
            rareRewardParticipated: true,
            rareRewardCreditedGrams: 600,
            rareRewardOutcomesRawValue: RareRewardOutcomeCodec.encode([.gold, .prism])
        ))

        let stratumID = UUID()
        context.insert(Stratum(
            id: stratumID,
            pebbleCount: 48,
            heightPt: 30,
            colorMixJSON: "[]",
            monthLabel: "2026年8月",
            grams: 12_000
        ))
        context.insert(Stratum(
            id: stratumID,
            pebbleCount: 48,
            heightPt: 30,
            colorMixJSON: "[]",
            monthLabel: "2026年8月",
            grams: 12_000
        ))
        try context.save()

        try SeedData.bootstrap(context: context)

        let prefs = try context.fetch(FetchDescriptor<Prefs>())
        XCTAssertEqual(prefs.count, 1)
        XCTAssertFalse(try XCTUnwrap(prefs.first).soundOn)
        XCTAssertTrue(try XCTUnwrap(prefs.first).hasEverImportedBedrock)
        // Session history and the singleton can arrive in either order through
        // CloudKit. One locally visible miss is not proof that a synced pity
        // value of nine was stale, so generic reconciliation must never move
        // the known counter backwards.
        XCTAssertEqual(try context.fetch(FetchDescriptor<GachaState>()).first?.sinceLastGold, 9)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<GachaState>()).first?.rewardCreditGrams,
            600
        )
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<GachaState>()).first?.rewardCreditRemainderGrams,
            100
        )
        XCTAssertEqual(try context.fetch(FetchDescriptor<Bedrock>()).map(\.hours), [120])

        let sessions = try context.fetch(FetchDescriptor<StudySession>())
        let strata = try context.fetch(FetchDescriptor<Stratum>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(try XCTUnwrap(sessions.first).isBaked)
        XCTAssertEqual(try XCTUnwrap(sessions.first).pebbleKind, .gold)
        XCTAssertEqual(
            RareRewardOutcomeCodec.decode(
                try XCTUnwrap(sessions.first).rareRewardOutcomesRawValue
            ),
            [.gold, .prism]
        )
        XCTAssertEqual(strata.count, 1)
        XCTAssertEqual(StrataMath.totalGrams(sessions: sessions, strata: strata), 12_000)
    }

    func testCloudPreferencesRestoreOnboardingAndNewestUsagePurpose() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)

        let older = Date(timeIntervalSince1970: 1_800_000_000)
        let newer = older.addingTimeInterval(60)
        context.insert(Prefs(
            hasCompletedOnboarding: true,
            usagePurposeRawValue: UsagePurpose.study.rawValue,
            usagePurposeUpdatedAt: older
        ))
        context.insert(Prefs(
            hasCompletedOnboarding: false,
            usagePurposeRawValue: UsagePurpose.work.rawValue,
            usagePurposeUpdatedAt: newer
        ))
        try context.save()

        try SeedData.bootstrap(context: context)

        let values = try context.fetch(FetchDescriptor<Prefs>())
        let prefs = try XCTUnwrap(values.first)
        XCTAssertEqual(values.count, 1)
        XCTAssertTrue(prefs.hasCompletedOnboarding)
        XCTAssertEqual(prefs.usagePurposeRawValue, UsagePurpose.work.rawValue)
        XCTAssertEqual(prefs.usagePurposeUpdatedAt, newer)
    }

    func testRareRewardPreferenceDefaultsAndInvalidValuesFallBackToNoDraw() {
        let defaults = Prefs()
        XCTAssertEqual(defaults.rareRewardModeRawValue, RareRewardMode.off.rawValue)
        XCTAssertNil(defaults.rareRewardModeUpdatedAt)

        let initializedWithInvalidValue = Prefs(
            rareRewardModeRawValue: "future-unknown-mode"
        )
        XCTAssertEqual(
            initializedWithInvalidValue.rareRewardModeRawValue,
            RareRewardMode.off.rawValue
        )
        XCTAssertEqual(RareRewardMode.resolved("future-unknown-mode"), .off)
        XCTAssertEqual(RareRewardMode.resolved(nil), .off)
        XCTAssertNil(RareRewardMode.selectedMode(preferences: [defaults]))
        XCTAssertEqual(RareRewardMode.resolved(preferences: [defaults]), .off)
        XCTAssertFalse(RareRewardMode.hasExplicitSelection(preferences: [defaults]))
    }

    func testUndatedLegacyStandardIsUnselectedAndCannotEnableDraws() {
        let legacy = Prefs(
            rareRewardModeRawValue: RareRewardMode.standard.rawValue,
            rareRewardModeUpdatedAt: nil,
            hasCompletedOnboarding: true
        )

        XCTAssertEqual(legacy.rareRewardModeRawValue, RareRewardMode.standard.rawValue)
        XCTAssertNil(RareRewardMode.selectedMode(preferences: [legacy]))
        XCTAssertEqual(RareRewardMode.resolved(preferences: [legacy]), .off)
        XCTAssertFalse(RareRewardMode.hasExplicitSelection(preferences: [legacy]))
    }

    func testEveryExplicitRareRewardChoiceResolvesWithoutChangingItsMeaning() {
        for mode in RareRewardMode.choiceOrder {
            let prefs = Prefs(
                rareRewardModeRawValue: mode.rawValue,
                rareRewardModeUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            XCTAssertEqual(RareRewardMode.selectedMode(preferences: [prefs]), mode)
            XCTAssertEqual(RareRewardMode.resolved(preferences: [prefs]), mode)
            XCTAssertTrue(RareRewardMode.hasExplicitSelection(preferences: [prefs]))
        }
    }

    func testRareRewardDuplicateMergeUsesNewestTimestampEvenWhenItReenablesStandard() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)

        let older = Date(timeIntervalSince1970: 1_800_000_000)
        let newer = older.addingTimeInterval(60)
        context.insert(Prefs(
            rareRewardModeRawValue: RareRewardMode.off.rawValue,
            rareRewardModeUpdatedAt: older
        ))
        context.insert(Prefs(
            rareRewardModeRawValue: RareRewardMode.standard.rawValue,
            rareRewardModeUpdatedAt: newer
        ))
        try context.save()

        try SeedData.bootstrap(context: context)

        let values = try context.fetch(FetchDescriptor<Prefs>())
        let prefs = try XCTUnwrap(values.first)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(prefs.rareRewardModeRawValue, RareRewardMode.standard.rawValue)
        XCTAssertEqual(prefs.rareRewardModeUpdatedAt, newer)
    }

    func testRareRewardUndatedDuplicateTieChoosesOff() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)

        context.insert(Prefs(
            rareRewardModeRawValue: RareRewardMode.quiet.rawValue
        ))
        context.insert(Prefs(
            rareRewardModeRawValue: RareRewardMode.off.rawValue
        ))
        try context.save()

        try SeedData.bootstrap(context: context)

        let values = try context.fetch(FetchDescriptor<Prefs>())
        let prefs = try XCTUnwrap(values.first)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(prefs.rareRewardModeRawValue, RareRewardMode.off.rawValue)
        XCTAssertNil(prefs.rareRewardModeUpdatedAt)
    }

    func testThemeNameDisclosureDefaultsOffAndOptOutWinsDuplicateMerge() throws {
        XCTAssertFalse(Prefs().showsThemeNameExternally)

        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)

        let canonical = try XCTUnwrap(
            context.fetch(FetchDescriptor<Prefs>()).first
        )
        canonical.showsThemeNameExternally = true
        context.insert(Prefs(showsThemeNameExternally: false))
        try context.save()

        try SeedData.bootstrap(context: context)

        let reconciled = try context.fetch(FetchDescriptor<Prefs>())
        XCTAssertEqual(reconciled.count, 1)
        XCTAssertFalse(
            try XCTUnwrap(reconciled.first).showsThemeNameExternally
        )
    }

    func testDuplicateCompletionKindsConvergeToSameRareResult() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)
        let sessionID = UUID()
        let end = Date.now
        for kind in [PebbleKind.normal, .prism, .gold] {
            context.insert(StudySession(
                id: sessionID,
                startAt: end.addingTimeInterval(-1_500),
                endAt: end,
                seconds: 1_500,
                source: .timer,
                pebbleKind: kind,
                grams: 250,
                deviceDayKey: FairnessPolicy.deviceDayKey(for: end)
            ))
        }
        try context.save()

        try SeedData.bootstrap(context: context)

        let sessions = try context.fetch(FetchDescriptor<StudySession>())
            .filter { $0.id == sessionID }
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.pebbleKind, .prism)
    }

    func testSessionReconnectsWhenSubjectArrivesAfterCloudCompletion() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)
        let subjectID = UUID()
        let end = Date.now
        let session = StudySession(
            subject: nil,
            startAt: end.addingTimeInterval(-1_500),
            endAt: end,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: end),
            subjectNameSnapshot: "顧客提案",
            subjectColorHexSnapshot: "#3FA57C",
            subjectIDSnapshot: subjectID
        )
        context.insert(session)
        try context.save()
        try SeedData.bootstrap(context: context)
        XCTAssertNil(session.subject)

        let lateSubject = Subject(
            id: subjectID,
            name: "顧客提案",
            colorHex: "#3FA57C",
            sortOrder: 20
        )
        context.insert(lateSubject)
        try context.save()
        try SeedData.bootstrap(context: context)

        XCTAssertTrue(session.subject === lateSubject)
        XCTAssertEqual(session.displaySubjectName, "顧客提案")
    }

    func testPresetDuplicateRehomesExistingSessions() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)

        let duplicate = Subject(
            name: "英語",
            colorHex: Constants.Color.english,
            sortOrder: 9
        )
        context.insert(duplicate)
        let now = Date.now
        let session = StudySession(
            subject: duplicate,
            startAt: now.addingTimeInterval(-1_500),
            endAt: now,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: now)
        )
        context.insert(session)
        try context.save()

        try SeedData.bootstrap(context: context)

        let englishSubjects = try context.fetch(FetchDescriptor<Subject>())
            .filter { $0.name == "英語" }
        XCTAssertEqual(englishSubjects.count, 1)
        XCTAssertTrue(session.subject === englishSubjects.first)
    }

    func testOverlappingCloudBakesCountEverySessionExactlyOnce() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)

        let subject = try XCTUnwrap(context.fetch(FetchDescriptor<Subject>()).first)
        let now = Date.now
        let values = (0..<3).map { index in
            StudySession(
                id: UUID(),
                subject: subject,
                startAt: now.addingTimeInterval(Double(-1_500 * (index + 1))),
                endAt: now.addingTimeInterval(Double(-1_500 * index)),
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: FairnessPolicy.deviceDayKey(for: now),
                isBaked: true
            )
        }
        values.forEach(context.insert)
        context.insert(Stratum(
            pebbleCount: 2,
            heightPt: 10,
            colorMixJSON: "[]",
            monthLabel: "2026年8月",
            grams: 500,
            sessionIDs: [values[0].id, values[1].id]
        ))
        context.insert(Stratum(
            pebbleCount: 2,
            heightPt: 10,
            colorMixJSON: "[]",
            monthLabel: "2026年8月",
            grams: 500,
            sessionIDs: [values[1].id, values[2].id]
        ))
        try context.save()

        try SeedData.bootstrap(context: context)

        let sessions = try context.fetch(FetchDescriptor<StudySession>())
        let strata = try context.fetch(FetchDescriptor<Stratum>())
        XCTAssertEqual(Set(strata.flatMap(\.sessionIDs)).count, 3)
        XCTAssertEqual(strata.reduce(0) { $0 + $1.pebbleCount }, 3)
        XCTAssertEqual(StrataMath.totalGrams(sessions: sessions, strata: strata), 750)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: sessions, strata: strata), 3)
    }

    func testBootstrapRepairsBakedFlagWithoutMatchingStratum() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)

        let now = Date.now
        let session = StudySession(
            startAt: now.addingTimeInterval(-1_500),
            endAt: now,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: now),
            isBaked: true
        )
        context.insert(session)
        try context.save()

        try SeedData.bootstrap(context: context)

        XCTAssertFalse(session.isBaked)
        XCTAssertEqual(StrataMath.totalGrams(sessions: [session], strata: []), 250)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: [session], strata: []), 1)
    }

    func testDeletingSubjectKeepsHistoricalNameColorAndMass() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)

        let subject = try XCTUnwrap(context.fetch(FetchDescriptor<Subject>()).first)
        let expectedName = subject.name
        let expectedColor = subject.colorHex
        let now = Date.now
        let session = StudySession(
            subject: subject,
            startAt: now.addingTimeInterval(-1_500),
            endAt: now,
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: now)
        )
        context.insert(session)
        try context.save()

        session.subject = nil
        context.delete(subject)
        try context.save()

        let remaining = try XCTUnwrap(context.fetch(FetchDescriptor<StudySession>()).first)
        XCTAssertEqual(remaining.displaySubjectName, expectedName)
        XCTAssertEqual(remaining.displaySubjectColorHex, expectedColor)
        XCTAssertEqual(StrataMath.totalGrams(sessions: [remaining], strata: []), 250)
    }

    func testAchievementStonesDoNotChangeStudyMassOrPebbleCount() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)

        let subject = try XCTUnwrap(context.fetch(FetchDescriptor<Subject>()).first)
        context.insert(AchievementStone(subject: subject, kind: .perfectScore))
        context.insert(AchievementStone(subject: subject, kind: .examPass))
        try context.save()

        let stones = try context.fetch(FetchDescriptor<AchievementStone>())
        XCTAssertEqual(stones.count, 2)
        XCTAssertEqual(StrataMath.totalGrams(sessions: [], strata: []), 0)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: [], strata: []), 0)
    }

    func testVisibleAchievementPolicyKeepsLatestTwelveInStableOrder() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)
        let subject = try XCTUnwrap(context.fetch(FetchDescriptor<Subject>()).first)
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var stones: [AchievementStone] = []
        for index in 0..<14 {
            let date = base.addingTimeInterval(Double(index))
            let stone = AchievementStone(
                subject: subject,
                kind: index.isMultiple(of: 2) ? .perfectScore : .examPass,
                achievedAt: date,
                createdAt: date
            )
            context.insert(stone)
            stones.append(stone)
        }
        try context.save()

        let visible = AchievementStonePolicy.visibleStones(from: stones)
        XCTAssertEqual(visible.count, Constants.Jar.maximumVisibleAchievementStones)
        XCTAssertEqual(visible.map(\.id), Array(stones.dropFirst(2)).map(\.id))
    }

    func testAchievementRevisionEditsEveryLogicalDuplicateWithoutChangingMass() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let originalSubject = Subject(
            name: "英語",
            colorHex: "#FF647F",
            sortOrder: 0
        )
        let revisedSubject = Subject(
            name: "簿記",
            colorHex: "#70FFD8",
            sortOrder: 1
        )
        context.insert(originalSubject)
        context.insert(revisedSubject)
        let achievementID = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let first = AchievementStone(
            id: achievementID,
            subject: originalSubject,
            kind: .perfectScore,
            note: "模試",
            achievedAt: base,
            createdAt: base,
            revision: 2,
            updatedAt: base
        )
        let duplicate = AchievementStone(
            id: achievementID,
            subject: originalSubject,
            kind: .perfectScore,
            note: "模試",
            achievedAt: base,
            createdAt: base.addingTimeInterval(1),
            revision: 2,
            updatedAt: base
        )
        let session = StudySession(
            subject: originalSubject,
            startAt: base,
            endAt: base.addingTimeInterval(1_500),
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "revision-test"
        )
        context.insert(first)
        context.insert(duplicate)
        context.insert(session)
        try context.save()
        let massBefore = StrataMath.totalGrams(sessions: [session], strata: [])

        let revisedDate = base.addingTimeInterval(86_400)
        let revisionDate = base.addingTimeInterval(100_000)
        AchievementStoneRevisionPolicy.edit(
            [first, duplicate],
            subject: revisedSubject,
            kind: .examPass,
            note: "  簿記2級 合格  ",
            achievedAt: revisedDate,
            now: revisionDate
        )
        try context.save()

        for stone in [first, duplicate] {
            XCTAssertEqual(stone.revision, 3)
            XCTAssertNil(stone.deletedAt)
            XCTAssertEqual(stone.kind, .examPass)
            XCTAssertEqual(stone.note, "簿記2級 合格")
            XCTAssertEqual(stone.achievedAt, revisedDate)
            XCTAssertEqual(stone.subject?.id, revisedSubject.id)
            XCTAssertEqual(stone.subjectNameSnapshot, revisedSubject.safeDisplayName)
            XCTAssertEqual(stone.subjectColorHexSnapshot, revisedSubject.colorHex)
            XCTAssertEqual(stone.updatedAt, revisionDate)
        }
        XCTAssertEqual(StrataMath.totalGrams(sessions: [session], strata: []), massBefore)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: [session], strata: []), 1)
    }

    func testAchievementDeleteUsesTombstoneAndUndoRestoresAtHigherRevision() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let subject = Subject(name: "資格", colorHex: "#70FFD8", sortOrder: 0)
        context.insert(subject)
        let base = Date(timeIntervalSinceReferenceDate: 3_000_000)
        let stone = AchievementStone(
            subject: subject,
            kind: .examPass,
            note: "簿記2級",
            achievedAt: base,
            createdAt: base,
            updatedAt: base
        )
        context.insert(stone)
        try context.save()
        let snapshot = AchievementStoneRevisionSnapshot(stone)

        let deletionDate = base.addingTimeInterval(10)
        AchievementStoneRevisionPolicy.delete([stone], now: deletionDate)
        try context.save()

        XCTAssertEqual(stone.revision, 2)
        XCTAssertEqual(stone.deletedAt, deletionDate)
        XCTAssertTrue(AchievementStonePolicy.visibleStones(from: [stone]).isEmpty)
        XCTAssertTrue(try context.fetch(BoundedHistoryPolicy.achievementCandidateDescriptor(
            epochID: nil,
            limit: 10
        )).isEmpty)
        XCTAssertTrue(try context.fetch(HomeProjectionPolicy.achievementCandidateDescriptor()).isEmpty)
        XCTAssertEqual(try context.fetchCount(
            AccumulationOverviewLoaderPolicy.achievementCountDescriptor(currentEpochID: nil)
        ), 0)
        XCTAssertEqual(StrataMath.totalGrams(sessions: [], strata: []), 0)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: [], strata: []), 0)

        let undoDate = deletionDate.addingTimeInterval(10)
        AchievementStoneRevisionPolicy.restore(
            [stone],
            snapshot: snapshot,
            subject: subject,
            now: undoDate
        )
        try context.save()

        XCTAssertEqual(stone.revision, 3)
        XCTAssertNil(stone.deletedAt)
        XCTAssertEqual(stone.note, "簿記2級")
        XCTAssertEqual(stone.kind, .examPass)
        XCTAssertEqual(AchievementStonePolicy.visibleStones(from: [stone]).map(\.id), [stone.id])
    }

    func testAchievementTombstoneWinsStaleOfflineDuplicateAndBootstrapKeepsItDeleted() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let id = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 4_000_000)
        let staleActive = AchievementStone(
            id: id,
            kind: .perfectScore,
            note: "古い端末の編集",
            achievedAt: base,
            createdAt: base,
            revision: 4,
            updatedAt: base.addingTimeInterval(100)
        )
        let tombstone = AchievementStone(
            id: id,
            kind: .examPass,
            note: "削除前",
            achievedAt: base,
            createdAt: base.addingTimeInterval(1),
            revision: 5,
            deletedAt: base.addingTimeInterval(50),
            updatedAt: base.addingTimeInterval(50)
        )
        context.insert(staleActive)
        context.insert(tombstone)
        try context.save()

        XCTAssertTrue(
            AchievementStonePolicy.canonicalStone(from: [staleActive, tombstone]) === tombstone
        )
        XCTAssertTrue(AchievementStonePolicy.visibleStones(from: [staleActive, tombstone]).isEmpty)

        try SeedData.bootstrap(context: context)

        let surviving = try context.fetch(FetchDescriptor<AchievementStone>())
        XCTAssertEqual(surviving.count, 1)
        XCTAssertEqual(surviving.first?.id, id)
        XCTAssertEqual(surviving.first?.revision, 5)
        XCTAssertNotNil(surviving.first?.deletedAt)
        XCTAssertTrue(AchievementStonePolicy.visibleStones(from: surviving).isEmpty)
    }

    func testLateStaleAchievementCandidateIsSuppressedAcrossBoundedQueryPaths() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let id = UUID()
        let olderDate = Date.now.addingTimeInterval(-30 * 86_400)
        let lateCandidateDate = Date.now.addingTimeInterval(-60)
        let tombstone = AchievementStone(
            id: id,
            kind: .examPass,
            note: "削除済み",
            achievedAt: olderDate,
            createdAt: olderDate,
            revision: 9,
            deletedAt: olderDate.addingTimeInterval(10),
            updatedAt: olderDate.addingTimeInterval(10)
        )
        let lateStale = AchievementStone(
            id: id,
            kind: .perfectScore,
            note: "未同期端末から後着",
            achievedAt: lateCandidateDate,
            createdAt: lateCandidateDate,
            revision: 8,
            updatedAt: lateCandidateDate
        )
        context.insert(tombstone)
        context.insert(lateStale)
        try context.save()

        let launch = try BoundedLaunchPreparation.prepare(
            context: context,
            localFocusEpochID: nil,
            hasLocalFocus: false,
            pendingCompletionID: nil
        )
        XCTAssertFalse(launch.hasSyncedUsageEvidence)

        let candidatePages = [
            try context.fetch(HomeProjectionPolicy.achievementCandidateDescriptor()),
            try context.fetch(BoundedHistoryPolicy.achievementCandidateDescriptor(
                epochID: nil,
                limit: 10
            )),
            try context.fetch(AccumulationOverviewLoaderPolicy.achievementCandidatePageDescriptor(
                currentEpochID: nil
            ))
        ]
        for candidates in candidatePages {
            XCTAssertTrue(candidates.contains { $0 === lateStale })
            let resolved = try AchievementStonePolicy.resolvedVisibleCandidates(
                from: candidates,
                context: context
            )
            XCTAssertFalse(resolved.contains { $0.id == id })
        }

        let homeCount = try HomeProjectionPolicy.currentAchievementCount(
            context: context,
            resetMarkers: [],
            resolvedCandidates: [],
            loadedCandidateRowCount: 1
        )
        XCTAssertEqual(homeCount, .init(count: 0, isLowerBound: false))
        XCTAssertTrue(
            try context.fetch(AchievementStonePolicy.canonicalDescriptor(
                id: id,
                dataEpochID: nil
            )).first === tombstone
        )
    }

    func testAchievementTombstoneWinsSameRevisionConflict() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let id = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 5_000_000)
        let active = AchievementStone(
            id: id,
            kind: .perfectScore,
            achievedAt: base,
            createdAt: base,
            revision: 8,
            updatedAt: base.addingTimeInterval(20)
        )
        let deleted = AchievementStone(
            id: id,
            kind: .perfectScore,
            achievedAt: base,
            createdAt: base,
            revision: 8,
            deletedAt: base.addingTimeInterval(10),
            updatedAt: base.addingTimeInterval(10)
        )
        context.insert(active)
        context.insert(deleted)
        try context.save()

        XCTAssertTrue(
            AchievementStonePolicy.canonicalStone(from: [active, deleted]) === deleted
        )
        XCTAssertTrue(
            try context.fetch(AchievementStonePolicy.canonicalDescriptor(
                id: id,
                dataEpochID: nil
            )).first === deleted
        )
    }

    func testBoundedAchievementMutationPageAlwaysIncludesCanonicalTombstone() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let id = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 5_050_000)
        for revision in 1...20 {
            context.insert(AchievementStone(
                id: id,
                kind: .examPass,
                note: "revision \(revision)",
                achievedAt: base,
                createdAt: base.addingTimeInterval(Double(revision)),
                revision: revision,
                deletedAt: revision == 20 ? base.addingTimeInterval(100) : nil,
                updatedAt: base.addingTimeInterval(Double(revision))
            ))
        }
        try context.save()

        let mutationPage = try context.fetch(
            BoundedHistoryPolicy.achievementRevisionDescriptor(
                id: id,
                epochID: nil,
                limit: 16
            )
        )
        XCTAssertEqual(mutationPage.count, 16)
        XCTAssertEqual(mutationPage.first?.revision, 20)
        XCTAssertNotNil(mutationPage.first?.deletedAt)

        let subject = Subject(name: "資格", colorHex: "#70FFD8", sortOrder: 0)
        AchievementStoneRevisionPolicy.edit(
            mutationPage,
            subject: subject,
            kind: .perfectScore,
            note: "オフライン編集",
            achievedAt: base,
            now: base.addingTimeInterval(200)
        )
        XCTAssertTrue(AchievementStonePolicy.visibleStones(from: mutationPage).isEmpty)
        XCTAssertTrue(mutationPage.allSatisfy { $0.deletedAt != nil })
    }

    func testAchievementEditCannotImplicitlyResurrectCanonicalTombstone() {
        let id = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 5_100_000)
        let deletionDate = base.addingTimeInterval(20)
        let active = AchievementStone(
            id: id,
            kind: .perfectScore,
            note: "古い端末",
            achievedAt: base,
            createdAt: base,
            revision: 3,
            updatedAt: base.addingTimeInterval(30)
        )
        let deleted = AchievementStone(
            id: id,
            kind: .examPass,
            note: "削除済み",
            achievedAt: base,
            createdAt: base,
            revision: 4,
            deletedAt: deletionDate,
            updatedAt: deletionDate
        )
        let subject = Subject(name: "資格", colorHex: "#70FFD8", sortOrder: 0)

        AchievementStoneRevisionPolicy.edit(
            [active, deleted],
            subject: subject,
            kind: .workMilestone,
            note: "オフライン編集",
            achievedAt: base,
            now: base.addingTimeInterval(40)
        )

        for stone in [active, deleted] {
            XCTAssertEqual(stone.revision, 5)
            XCTAssertEqual(stone.deletedAt, deletionDate)
        }
        XCTAssertTrue(AchievementStonePolicy.visibleStones(from: [active, deleted]).isEmpty)
    }

    func testBootstrapReconcilesDuplicateAchievementAndPreservesSnapshots() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)
        let subject = try XCTUnwrap(context.fetch(FetchDescriptor<Subject>()).first)
        let id = UUID()
        let older = Date.now.addingTimeInterval(-100)
        context.insert(AchievementStone(
            id: id,
            subject: subject,
            kind: .perfectScore,
            note: "  期末テスト  ",
            achievedAt: older,
            createdAt: older
        ))
        context.insert(AchievementStone(
            id: id,
            kind: .examPass,
            achievedAt: .now.addingTimeInterval(3_600),
            createdAt: .now
        ))
        try context.save()

        try SeedData.bootstrap(context: context)

        let stones = try context.fetch(FetchDescriptor<AchievementStone>())
        let stone = try XCTUnwrap(stones.first)
        XCTAssertEqual(stones.count, 1)
        XCTAssertEqual(stone.id, id)
        XCTAssertEqual(stone.displaySubjectName, subject.name)
        XCTAssertEqual(stone.displaySubjectColorHex, subject.colorHex)
        XCTAssertLessThanOrEqual(stone.achievedAt, .now)
    }

    func testBootstrapMigratesLegacyStratumToMovableAggregateIdempotently() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)
        let subject = try XCTUnwrap(context.fetch(FetchDescriptor<Subject>()).first)
        let start = Date(timeIntervalSince1970: 50_000)
        var sessions: [StudySession] = []
        for index in 0..<10 {
            let session = StudySession(
                subject: subject,
                startAt: start.addingTimeInterval(Double(index * 1_500)),
                endAt: start.addingTimeInterval(Double((index + 1) * 1_500)),
                seconds: 1_500,
                source: index < 8 ? .timer : .manual,
                pebbleKind: index == 0 ? .gold : .normal,
                grams: index < 8 ? 250 : 600,
                deviceDayKey: "2026-08-30",
                isBaked: true
            )
            sessions.append(session)
            context.insert(session)
        }
        let stratumID = UUID()
        let stratum = Stratum(
            id: stratumID,
            bakedAt: start.addingTimeInterval(20_000),
            pebbleCount: sessions.count,
            heightPt: 42,
            colorMixJSON: StrataMath.encodeColorMix(
                StrataMath.colorMix(hexColors: sessions.map(\.displaySubjectColorHex))
            ),
            monthLabel: "2026年8月",
            grams: sessions.reduce(0) { $0 + $1.grams },
            sessionIDs: sessions.map(\.id)
        )
        context.insert(stratum)
        context.insert(Bedrock(hours: 200))
        try context.save()

        try SeedData.bootstrap(context: context)
        try SeedData.bootstrap(context: context)

        let aggregates = try context.fetch(FetchDescriptor<AggregatePebble>())
        let aggregate = try XCTUnwrap(aggregates.first { $0.id == stratumID })
        XCTAssertEqual(aggregates.filter { $0.id == stratumID }.count, 1)
        XCTAssertEqual(aggregate.pebbleCount, 10)
        XCTAssertEqual(aggregate.sessionIDs.count, 10)
        XCTAssertEqual(aggregate.measuredPebbleCount, 8)
        XCTAssertEqual(aggregate.manualPebbleCount, 2)
        XCTAssertEqual(aggregate.goldPebbleCount, 1)
        XCTAssertEqual(aggregate.subjectMix.first?.name, subject.name)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Stratum>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Bedrock>()).count, 1)
        XCTAssertEqual(
            StrataMath.totalGrams(sessions: sessions, aggregates: aggregates),
            sessions.reduce(0) { $0 + $1.grams }
        )
    }

    func testBootstrapCarriesTenLegacyAggregatesWithoutDeletingChildren() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)
        let base = Date(timeIntervalSince1970: 90_000)
        for index in 0..<10 {
            context.insert(Stratum(
                id: UUID(),
                bakedAt: base.addingTimeInterval(Double(index)),
                pebbleCount: 10,
                heightPt: 10,
                colorMixJSON: StrataMath.encodeColorMix([
                    StratumColorFraction(hex: Constants.Color.science, fraction: 1)
                ]),
                monthLabel: "2026年8月",
                grams: 2_500
            ))
        }
        try context.save()

        try SeedData.bootstrap(context: context)

        let aggregates = try context.fetch(FetchDescriptor<AggregatePebble>())
        let roots = AggregatePebblePolicy.activeRoots(from: aggregates)
        XCTAssertEqual(aggregates.count, 11)
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots.first?.level, 2)
        XCTAssertEqual(roots.first?.pebbleCount, 100)
        XCTAssertEqual(roots.first?.childAggregateCount, 10)
        XCTAssertTrue(try XCTUnwrap(roots.first).sessionIDs.isEmpty)
        XCTAssertEqual(try XCTUnwrap(roots.first).childAggregateIDs.count, 10)
        XCTAssertEqual(aggregates.filter { $0.parentAggregateID != nil }.count, 10)
        XCTAssertEqual(StrataMath.totalGrams(sessions: [], aggregates: aggregates), 25_000)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: [], aggregates: aggregates), 100)
    }

    func testBootstrapSafelyCompactsFlattenedHigherLevelLineage() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)
        let base = Date(timeIntervalSince1970: 120_000)
        let parentID = UUID()
        var allSessionIDs: [UUID] = []
        var childIDs: [UUID] = []

        for group in 0..<10 {
            var memberIDs: [UUID] = []
            for index in 0..<10 {
                let session = StudySession(
                    startAt: base.addingTimeInterval(Double(group * 10 + index)),
                    endAt: base.addingTimeInterval(Double(group * 10 + index + 1)),
                    seconds: 1_500,
                    source: .timer,
                    pebbleKind: index == 0 ? .gold : .normal,
                    grams: 250,
                    deviceDayKey: "2026-08-30",
                    isBaked: true
                )
                context.insert(session)
                memberIDs.append(session.id)
                allSessionIDs.append(session.id)
            }
            let child = AggregatePebble(
                level: 1,
                pebbleCount: 10,
                grams: 2_500,
                measuredPebbleCount: 10,
                goldPebbleCount: 1,
                colorMixJSON: "[]",
                periodStart: base,
                periodEnd: base.addingTimeInterval(100),
                sessionIDs: memberIDs,
                parentAggregateID: parentID
            )
            context.insert(child)
            childIDs.append(child.id)
        }
        let parent = AggregatePebble(
            id: parentID,
            level: 2,
            pebbleCount: 100,
            childAggregateCount: 10,
            grams: 25_000,
            measuredPebbleCount: 100,
            goldPebbleCount: 10,
            colorMixJSON: "[]",
            periodStart: base,
            periodEnd: base.addingTimeInterval(100),
            sessionIDs: allSessionIDs,
            childAggregateIDs: childIDs
        )
        context.insert(parent)
        try context.save()

        try SeedData.bootstrap(context: context)

        let aggregates = try context.fetch(FetchDescriptor<AggregatePebble>())
        let compacted = try XCTUnwrap(aggregates.first { $0.id == parentID })
        XCTAssertTrue(compacted.sessionIDs.isEmpty)
        XCTAssertEqual(compacted.childAggregateIDs.count, 10)
        XCTAssertEqual(compacted.grams, 25_000)
        XCTAssertEqual(compacted.goldPebbleCount, 10)
        XCTAssertEqual(
            AggregatePebblePolicy.descendantSessionIDs(of: compacted, in: aggregates).count,
            100
        )
        XCTAssertTrue(aggregates.allSatisfy {
            $0.sessionIDs.count <= 10 && $0.childAggregateIDs.count <= 10
        })
        let sessions = try context.fetch(FetchDescriptor<StudySession>())
        XCTAssertEqual(StrataMath.totalGrams(sessions: sessions, aggregates: aggregates), 25_000)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: sessions, aggregates: aggregates), 100)
    }

    func testBootstrapPreservesFlattenedLineageWhenAChildIsMissing() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)
        let parentID = UUID()
        let memberIDs = (0..<20).map { _ in UUID() }
        let child = AggregatePebble(
            level: 1,
            pebbleCount: 10,
            grams: 2_500,
            colorMixJSON: "[]",
            periodStart: .now,
            periodEnd: .now,
            sessionIDs: Array(memberIDs.prefix(10)),
            parentAggregateID: parentID
        )
        context.insert(child)
        let parent = AggregatePebble(
            id: parentID,
            level: 2,
            pebbleCount: 20,
            childAggregateCount: 2,
            grams: 5_000,
            colorMixJSON: "[]",
            periodStart: .now,
            periodEnd: .now,
            sessionIDs: memberIDs,
            childAggregateIDs: [child.id, UUID()]
        )
        context.insert(parent)
        try context.save()

        try SeedData.bootstrap(context: context)

        let preserved = try XCTUnwrap(
            context.fetch(FetchDescriptor<AggregatePebble>()).first { $0.id == parentID }
        )
        XCTAssertEqual(Set(preserved.sessionIDs), Set(memberIDs))
        XCTAssertEqual(preserved.childAggregateIDs.count, 2)
    }

    func testOverlappingOfflineCompletionsPreserveLaterSessionAsSelfReported() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)
        let firstID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let laterID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let start = Date(timeIntervalSince1970: 1_800_700_000)
        let laterStart = start.addingTimeInterval(30)
        let subject = FocusSubjectSnapshot(
            id: UUID(),
            name: "開発",
            colorHex: Constants.Color.mathematics
        )

        func completedTimer(
            sessionID: UUID,
            startedAt: Date,
            writer: String
        ) throws -> SyncedFocusTimer {
            var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
            try engine.startFocus(
                isPro: false,
                now: startedAt,
                sessionID: sessionID
            )
            let envelope = FocusRecoveryEnvelope(
                engine: engine,
                subject: subject,
                clockAnchor: nil,
                pendingCompletion: nil,
                savedAt: startedAt
            )
            return try SyncedFocusTimer(
                sessionID: sessionID,
                status: .completed,
                payload: FocusCloudPayload(envelope: envelope),
                updatedAt: startedAt.addingTimeInterval(1_500),
                writerDeviceID: writer
            )
        }

        let firstTimer = try completedTimer(
            sessionID: firstID,
            startedAt: start,
            writer: "iphone"
        )
        let laterTimer = try completedTimer(
            sessionID: laterID,
            startedAt: laterStart,
            writer: "offline-mac"
        )
        context.insert(firstTimer)
        context.insert(laterTimer)
        let firstSession = StudySession(
            id: firstID,
            startAt: start,
            endAt: start.addingTimeInterval(1_500),
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "2027-01-03",
            isBaked: true
        )
        let laterSession = StudySession(
            id: laterID,
            startAt: laterStart,
            endAt: laterStart.addingTimeInterval(1_500),
            seconds: 1_500,
            source: .timer,
            pebbleKind: .prism,
            grams: 250,
            deviceDayKey: "2027-01-03",
            isBaked: true
        )
        context.insert(firstSession)
        context.insert(laterSession)
        let ancestorID = UUID()
        let derived = AggregatePebble(
            level: 1,
            pebbleCount: 2,
            grams: 500,
            colorMixJSON: "[]",
            periodStart: start,
            periodEnd: laterStart.addingTimeInterval(1_500),
            sessionIDs: [firstID, laterID],
            parentAggregateID: ancestorID
        )
        context.insert(derived)
        let ancestor = AggregatePebble(
            id: ancestorID,
            level: 2,
            pebbleCount: 2,
            childAggregateCount: 1,
            grams: 500,
            colorMixJSON: "[]",
            periodStart: start,
            periodEnd: laterStart.addingTimeInterval(1_500),
            childAggregateIDs: [derived.id]
        )
        context.insert(ancestor)
        // A membership-less legacy projection prevents the general stratum
        // reconciler from clearing every historical isBaked flag. Conflict
        // cleanup must still explicitly release this surviving member.
        context.insert(Stratum(
            pebbleCount: 0,
            heightPt: 0,
            colorMixJSON: "[]",
            monthLabel: "legacy",
            grams: 0
        ))
        try context.save()

        XCTAssertEqual(
            FocusSyncPolicy.supersededSessionIDs(
                from: [laterTimer.policySnapshot, firstTimer.policySnapshot]
            ),
            Set([laterID])
        )
        try SeedData.bootstrap(context: context)

        var remaining = try context.fetch(FetchDescriptor<StudySession>())
            .sorted { $0.startAt < $1.startAt }
        XCTAssertEqual(remaining.map(\.id), [firstID, laterID])
        XCTAssertEqual(remaining[0].source, .timer)
        XCTAssertEqual(remaining[1].source, .timerDemoted)
        XCTAssertEqual(remaining[1].pebbleKind, .normal)
        XCTAssertTrue(remaining.allSatisfy { !$0.isBaked })
        XCTAssertFalse(try context.fetch(FetchDescriptor<AggregatePebble>())
            .contains { $0.id == derived.id })
        XCTAssertFalse(try context.fetch(FetchDescriptor<AggregatePebble>())
            .contains { $0.id == ancestor.id })
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<GachaState>()).first?.sinceLastGold,
            1
        )
        XCTAssertEqual(
            StrataMath.totalGrams(
                sessions: remaining,
                aggregates: try context.fetch(FetchDescriptor<AggregatePebble>())
            ),
            500
        )

        // Reconciliation is idempotent and a delayed duplicate cannot make the
        // preserved completion measured/rare again.
        try SeedData.bootstrap(context: context)
        remaining = try context.fetch(FetchDescriptor<StudySession>())
            .sorted { $0.startAt < $1.startAt }
        XCTAssertEqual(remaining.map(\.id), [firstID, laterID])
        XCTAssertEqual(remaining[1].source, .timerDemoted)
        XCTAssertEqual(remaining[1].pebbleKind, .normal)
        XCTAssertEqual(
            StrataMath.totalGrams(
                sessions: remaining,
                aggregates: try context.fetch(FetchDescriptor<AggregatePebble>())
            ),
            500
        )
    }
}
