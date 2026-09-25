import SwiftData
import XCTest
@testable import PomoGem

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
            FocusTimerDeviceClaim.self,
            RareRewardPendingCommit.self,
            RareRewardLedgerCursor.self
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

    func testBootstrapResolvesCloudDuplicatesWithoutMutatingSourceRows() throws {
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
        XCTAssertEqual(prefs.count, 2)
        let resolvedPrefs = try PrefsSyncPolicy.resolvedState(
            in: prefs,
            currentEpochID: nil
        )
        XCTAssertFalse(resolvedPrefs.soundOn)
        XCTAssertTrue(resolvedPrefs.hasEverImportedBedrock)
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
        XCTAssertEqual(sessions.count, 2)
        let logicalSessions = StudySessionSyncPolicy.canonicalSessions(from: sessions)
        XCTAssertEqual(logicalSessions.count, 1)
        XCTAssertEqual(
            RareRewardOutcomeCodec.decode(
                try XCTUnwrap(logicalSessions.first).rareRewardOutcomesRawValue
            ),
            [.gold, .prism]
        )
        XCTAssertEqual(strata.count, 1)
        XCTAssertEqual(
            StrataMath.totalGrams(sessions: logicalSessions, strata: strata),
            12_000
        )
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
        XCTAssertEqual(values.count, 3)
        let resolved = try PrefsSyncPolicy.resolvedState(
            in: values,
            currentEpochID: nil
        )
        XCTAssertTrue(resolved.hasCompletedOnboarding)
        XCTAssertEqual(resolved.usagePurposeRawValue, UsagePurpose.work.rawValue)
        XCTAssertEqual(resolved.usagePurposeUpdatedAt, newer)
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
        XCTAssertEqual(values.count, 3)
        let resolved = try PrefsSyncPolicy.resolvedState(
            in: values,
            currentEpochID: nil
        )
        XCTAssertEqual(
            resolved.rareRewardModeRawValue,
            RareRewardMode.standard.rawValue
        )
        XCTAssertEqual(resolved.rareRewardModeUpdatedAt, newer)
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
        XCTAssertEqual(values.count, 3)
        let resolved = try PrefsSyncPolicy.resolvedState(
            in: values,
            currentEpochID: nil
        )
        XCTAssertEqual(resolved.rareRewardModeRawValue, RareRewardMode.off.rawValue)
        XCTAssertNil(resolved.rareRewardModeUpdatedAt)
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
        XCTAssertEqual(reconciled.count, 2)
        XCTAssertTrue(canonical.showsThemeNameExternally)
        XCTAssertFalse(try PrefsSyncPolicy.resolvedState(
            in: reconciled,
            currentEpochID: nil
        ).showsThemeNameExternally)
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
        XCTAssertEqual(sessions.count, 3)
        let logical = StudySessionSyncPolicy.canonicalSessions(from: sessions)
        XCTAssertEqual(logical.count, 1)
        XCTAssertEqual(logical.first?.pebbleKind, .prism)
    }

    func testLateSubjectDeliveryKeepsSessionRelationshipReadOnly() throws {
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

        XCTAssertNil(session.subject)
        XCTAssertTrue(
            SubjectSyncPolicy.canonical(from: [lateSubject]) === lateSubject
        )
        XCTAssertEqual(session.displaySubjectName, "顧客提案")
    }

    func testPresetLookalikeSourceRowsAndRelationshipsAreRetained() throws {
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
        XCTAssertEqual(englishSubjects.count, 2)
        XCTAssertTrue(session.subject === duplicate)
    }

    func testOverlappingLocalMembershipCountsEverySessionExactlyOnce() throws {
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

    func testBootstrapIgnoresLegacyBakedFlagWithoutLocalMembership() throws {
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

        XCTAssertTrue(session.isBaked)
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

    func testAchievementRevisionEditsOnlyOnePhysicalReplicaWithoutChangingMass() throws {
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

        XCTAssertEqual(first.revision, 2)
        XCTAssertEqual(first.kind, .perfectScore)
        XCTAssertEqual(first.note, "模試")
        XCTAssertEqual(first.subject?.id, originalSubject.id)

        XCTAssertEqual(duplicate.revision, 3)
        XCTAssertNil(duplicate.deletedAt)
        XCTAssertEqual(duplicate.kind, .examPass)
        XCTAssertEqual(duplicate.note, "簿記2級 合格")
        XCTAssertEqual(duplicate.achievedAt, revisedDate)
        XCTAssertEqual(duplicate.subject?.id, revisedSubject.id)
        XCTAssertEqual(duplicate.subjectNameSnapshot, revisedSubject.safeDisplayName)
        XCTAssertEqual(duplicate.subjectColorHexSnapshot, revisedSubject.colorHex)
        XCTAssertEqual(duplicate.updatedAt, revisionDate)
        XCTAssertTrue(
            AchievementStonePolicy.canonicalStone(from: [first, duplicate]) === duplicate
        )
        XCTAssertEqual(StrataMath.totalGrams(sessions: [session], strata: []), massBefore)
        XCTAssertEqual(StrataMath.totalPebbleCount(sessions: [session], strata: []), 1)
    }

    func testEditingAMilestoneOfADeletedThemeKeepsThatTheme() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let deletedTheme = Subject(name: "英検", colorHex: "#FF647F", sortOrder: 0)
        let liveTheme = Subject(name: "数学", colorHex: "#6BE4FF", sortOrder: 1)
        context.insert(deletedTheme)
        context.insert(liveTheme)
        let base = Date(timeIntervalSinceReferenceDate: 4_000_000)
        let stone = AchievementStone(
            subject: deletedTheme,
            kind: .examPass,
            note: "2級",
            achievedAt: base,
            createdAt: base,
            updatedAt: base
        )
        context.insert(stone)
        try context.save()
        // Settings deletes a theme as a tombstone; the stone keeps its link.
        deletedTheme.isArchived = true
        deletedTheme.deletedAt = base.addingTimeInterval(10)
        try context.save()

        let revisedDate = base.addingTimeInterval(86_400)
        let editDate = base.addingTimeInterval(100_000)
        XCTAssertEqual(
            AchievementStoneRevisionPolicy.editKeepingSubject(
                [stone],
                kind: .examPass,
                note: "  2級 合格  ",
                achievedAt: revisedDate,
                now: editDate
            ),
            .applied
        )
        try context.save()

        XCTAssertEqual(stone.revision, 2)
        XCTAssertEqual(stone.note, "2級 合格")
        XCTAssertEqual(stone.achievedAt, revisedDate)
        XCTAssertEqual(stone.updatedAt, editDate)
        XCTAssertNil(stone.deletedAt)
        XCTAssertEqual(stone.subject?.id, deletedTheme.id, "The stone must not move to another theme")
        XCTAssertEqual(stone.subjectNameSnapshot, "英検")
        XCTAssertEqual(stone.subjectColorHexSnapshot, "#FF647F")
        XCTAssertEqual(stone.displaySubjectName, "英検")
        XCTAssertNotEqual(stone.subject?.id, liveTheme.id)
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
        let deletionMutationID = UUID(
            uuidString: "A1000000-0000-0000-0000-000000000001"
        )!
        AchievementStoneRevisionPolicy.delete(
            [stone],
            deletionMutationID: deletionMutationID,
            now: deletionDate
        )
        try context.save()

        XCTAssertEqual(stone.revision, 2)
        XCTAssertEqual(stone.deletedAt, deletionDate)
        XCTAssertEqual(stone.deletionRevision, 2)
        XCTAssertEqual(stone.deletionMutationID, deletionMutationID)
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
        XCTAssertEqual(stone.deletionRevision, 2)
        XCTAssertEqual(stone.deletionMutationID, deletionMutationID)
        XCTAssertEqual(stone.restoredDeletionMutationID, deletionMutationID)
        XCTAssertEqual(stone.note, "簿記2級")
        XCTAssertEqual(stone.kind, .examPass)
        XCTAssertEqual(AchievementStonePolicy.visibleStones(from: [stone]).map(\.id), [stone.id])

        // The restore updated the only physical tombstone in place. Its
        // retained deletion event still rejects a later higher-revision edit
        // from an offline device that never observed or acknowledged delete.
        let lateUnacknowledgedEdit = AchievementStone(
            id: stone.id,
            subject: subject,
            kind: .workMilestone,
            note: "未観測端末の後着編集",
            achievedAt: base,
            createdAt: base,
            revision: 4,
            updatedAt: undoDate.addingTimeInterval(1)
        )
        XCTAssertTrue(AchievementStonePolicy.canonicalStone(
            from: [lateUnacknowledgedEdit, stone]
        ) === stone)
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
        XCTAssertEqual(surviving.count, 2)
        XCTAssertTrue(surviving.contains { $0 === staleActive })
        XCTAssertTrue(surviving.contains { $0 === tombstone })
        XCTAssertTrue(
            AchievementStonePolicy.canonicalStone(from: surviving) === tombstone
        )
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
        let exact = try context.fetch(AchievementStonePolicy.canonicalDescriptor(
            id: id,
            dataEpochID: nil
        ))
        XCTAssertTrue(
            AchievementStonePolicy.canonicalStone(from: exact) === tombstone
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
        let exact = try context.fetch(AchievementStonePolicy.canonicalDescriptor(
            id: id,
            dataEpochID: nil
        ))
        XCTAssertTrue(
            AchievementStonePolicy.canonicalStone(from: exact) === deleted
        )
    }

    func testHostileAchievementRevisionCannotWinAndMutationRepairsIt() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let id = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 5_025_000)
        let valid = AchievementStone(
            id: id,
            kind: .perfectScore,
            note: "valid",
            achievedAt: base,
            createdAt: base,
            revision: 7,
            updatedAt: base
        )
        let hostile = AchievementStone(
            id: id,
            kind: .examPass,
            note: "hostile",
            achievedAt: base,
            createdAt: base,
            revision: 8,
            deletedAt: base,
            updatedAt: base.addingTimeInterval(100)
        )
        hostile.revision = Int.max
        context.insert(valid)
        context.insert(hostile)
        try context.save()

        XCTAssertTrue(
            AchievementStonePolicy.canonicalStone(from: [valid, hostile]) === valid
        )
        let exact = try context.fetch(AchievementStonePolicy.canonicalDescriptor(
            id: id,
            dataEpochID: nil
        ))
        XCTAssertTrue(
            AchievementStonePolicy.canonicalStone(from: exact) === valid
        )

        let subject = Subject(name: "修復", colorHex: "#123456", sortOrder: 0)
        XCTAssertEqual(
            AchievementStoneRevisionPolicy.edit(
                [valid, hostile],
                subject: subject,
                kind: .workMilestone,
                note: "repaired",
                achievedAt: base,
                now: base.addingTimeInterval(200)
            ),
            .applied
        )
        XCTAssertEqual(valid.revision, 8)
        XCTAssertEqual(hostile.revision, Int.max)
        XCTAssertEqual(valid.note, "repaired")
        XCTAssertEqual(hostile.note, "hostile")
        XCTAssertNil(valid.deletedAt)
        XCTAssertNotNil(hostile.deletedAt)
    }

    func testBoundedAchievementMutationPageIncludesCompleteBoundedReplicaSet() throws {
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
                epochID: nil
            )
        )
        XCTAssertEqual(mutationPage.count, 20)
        XCTAssertEqual(
            BoundedHistoryPolicy.achievementRevisionDescriptor(
                id: id,
                epochID: nil
            ).fetchLimit,
            AchievementStonePolicy.maximumPhysicalRowsPerLogicalStone + 1
        )
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
        XCTAssertEqual(mutationPage.filter { $0.deletedAt != nil }.count, 1)
        XCTAssertEqual(mutationPage.first?.revision, 21)
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

        XCTAssertEqual(active.revision, 3)
        XCTAssertNil(active.deletedAt)
        XCTAssertEqual(deleted.revision, 5)
        XCTAssertEqual(deleted.deletedAt, deletionDate)
        XCTAssertTrue(AchievementStonePolicy.visibleStones(from: [active, deleted]).isEmpty)
    }

    func testAchievementRestoreRequiresDominantDeletionTokenAcknowledgement() {
        let id = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 5_150_000)
        let deleteX = UUID(uuidString: "A2000000-0000-0000-0000-000000000001")!
        let deleteY = UUID(uuidString: "A2000000-0000-0000-0000-000000000002")!
        let deleteLow = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let deleteHigh = UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!
        let tombstoneX = AchievementStone(
            id: id,
            kind: .examPass,
            achievedAt: base,
            createdAt: base,
            revision: 5,
            deletedAt: base,
            deletionMutationID: deleteX,
            deletionRevision: 5,
            updatedAt: base
        )
        let unobservedOfflineEdit = AchievementStone(
            id: id,
            kind: .workMilestone,
            achievedAt: base,
            createdAt: base,
            revision: 6,
            updatedAt: base.addingTimeInterval(1)
        )
        let restoredX = AchievementStone(
            id: id,
            kind: .examPass,
            achievedAt: base,
            createdAt: base,
            revision: 6,
            deletionMutationID: deleteX,
            deletionRevision: 5,
            restoredDeletionMutationID: deleteX,
            updatedAt: base.addingTimeInterval(2)
        )

        XCTAssertTrue(AchievementStonePolicy.canonicalStone(
            from: [tombstoneX, unobservedOfflineEdit]
        ) === tombstoneX)
        XCTAssertTrue(AchievementStonePolicy.canonicalStone(
            from: [restoredX, tombstoneX]
        ) === restoredX)

        let tombstoneY = AchievementStone(
            id: id,
            kind: .examPass,
            achievedAt: base,
            createdAt: base,
            revision: 7,
            deletedAt: base.addingTimeInterval(3),
            deletionMutationID: deleteY,
            deletionRevision: 7,
            updatedAt: base.addingTimeInterval(3)
        )
        let staleAcknowledgementEdit = AchievementStone(
            id: id,
            kind: .workMilestone,
            achievedAt: base,
            createdAt: base,
            revision: 8,
            deletionMutationID: deleteX,
            deletionRevision: 5,
            restoredDeletionMutationID: deleteX,
            updatedAt: base.addingTimeInterval(4)
        )
        let restoredY = AchievementStone(
            id: id,
            kind: .examPass,
            achievedAt: base,
            createdAt: base,
            revision: 9,
            deletionMutationID: deleteY,
            deletionRevision: 7,
            restoredDeletionMutationID: deleteY,
            updatedAt: base.addingTimeInterval(5)
        )
        XCTAssertTrue(AchievementStonePolicy.canonicalStone(
            from: [tombstoneX, restoredX, tombstoneY, staleAcknowledgementEdit]
        ) === tombstoneY)
        XCTAssertTrue(AchievementStonePolicy.canonicalStone(
            from: [restoredY, staleAcknowledgementEdit, tombstoneY]
        ) === restoredY)

        let concurrentLow = AchievementStone(
            id: id,
            kind: .examPass,
            achievedAt: base,
            createdAt: base,
            revision: 10,
            deletedAt: base.addingTimeInterval(6),
            deletionMutationID: deleteLow,
            deletionRevision: 10,
            updatedAt: base.addingTimeInterval(6)
        )
        let concurrentHigh = AchievementStone(
            id: id,
            kind: .examPass,
            achievedAt: base,
            createdAt: base,
            revision: 10,
            deletedAt: base.addingTimeInterval(7),
            deletionMutationID: deleteHigh,
            deletionRevision: 10,
            updatedAt: base.addingTimeInterval(7)
        )
        let restoredLow = AchievementStone(
            id: id,
            kind: .examPass,
            achievedAt: base,
            createdAt: base,
            revision: 11,
            deletionMutationID: deleteLow,
            deletionRevision: 10,
            restoredDeletionMutationID: deleteLow,
            updatedAt: base.addingTimeInterval(8)
        )
        let restoredHigh = AchievementStone(
            id: id,
            kind: .examPass,
            achievedAt: base,
            createdAt: base,
            revision: 11,
            deletionMutationID: deleteHigh,
            deletionRevision: 10,
            restoredDeletionMutationID: deleteHigh,
            updatedAt: base.addingTimeInterval(9)
        )
        XCTAssertTrue(AchievementStonePolicy.canonicalStone(
            from: [concurrentLow, restoredLow, concurrentHigh]
        ) === concurrentHigh)
        XCTAssertTrue(AchievementStonePolicy.canonicalStone(
            from: [restoredHigh, concurrentHigh, concurrentLow]
        ) === restoredHigh)
        XCTAssertTrue(AchievementStonePolicy.canonicalStone(
            from: Array([concurrentLow, concurrentHigh, restoredHigh].reversed())
        ) === restoredHigh)
        XCTAssertTrue(AchievementStonePolicy.canonicalStone(
            from: [restoredHigh]
        ) === restoredHigh)
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
        XCTAssertEqual(stones.count, 2)
        XCTAssertTrue(stones.allSatisfy { $0.id == id })
        let canonical = try XCTUnwrap(
            AchievementStonePolicy.canonicalStone(from: stones)
        )
        XCTAssertTrue(
            AchievementStonePolicy.canonicalStone(from: Array(stones.reversed())) === canonical
        )
        XCTAssertLessThanOrEqual(canonical.achievedAt, .now)
    }

    func testBootstrapMigratesLegacyStratumToMovableAggregateIdempotently() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)
        let subject = try XCTUnwrap(context.fetch(FetchDescriptor<Subject>()).first)
        let start = Date.now.addingTimeInterval(-50_000)
        var sessions: [StudySession] = []
        for index in 0..<10 {
            let duration = index < 8
                ? 1_500
                : ManualDuration.sixtyMinutes.seconds
            let sessionStart = start.addingTimeInterval(Double(index * 3_600))
            let session = StudySession(
                subject: subject,
                startAt: sessionStart,
                endAt: sessionStart.addingTimeInterval(Double(duration)),
                seconds: duration,
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
            bakedAt: start.addingTimeInterval(40_000),
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
        let base = Date.now.addingTimeInterval(-200_000)
        let parentID = UUID()
        var allSessionIDs: [UUID] = []
        var childIDs: [UUID] = []

        for group in 0..<10 {
            var memberIDs: [UUID] = []
            for index in 0..<10 {
                let offset = Double((group * 10 + index) * 1_500)
                let sessionStart = base.addingTimeInterval(offset)
                let session = StudySession(
                    startAt: sessionStart,
                    endAt: sessionStart.addingTimeInterval(1_500),
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
                periodStart: base.addingTimeInterval(Double(group * 10 * 1_500)),
                periodEnd: base.addingTimeInterval(Double((group + 1) * 10 * 1_500)),
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
            periodEnd: base.addingTimeInterval(100 * 1_500),
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

    func testOverlappingOfflineCompletionsPreserveBothUniqueSessionsAsMeasured() throws {
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
            let endedAt = startedAt.addingTimeInterval(1_500)
            guard case let .focusCompleted(completion) = engine.advance(at: endedAt) else {
                throw FocusCloudSyncError.invalidPayload
            }
            let envelope = FocusRecoveryEnvelope(
                engine: engine,
                subject: subject,
                clockAnchor: nil,
                pendingCompletion: completion,
                savedAt: endedAt
            )
            return try SyncedFocusTimer(
                sessionID: sessionID,
                status: .completed,
                payload: FocusCloudPayload(envelope: envelope),
                updatedAt: endedAt,
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
            rareRewardRuleVersion: Constants.Gacha.creditRuleVersion,
            rareRewardParticipated: true,
            rareRewardCreditedGrams: 250,
            rareRewardOutcomesRawValue: RareRewardOutcomeCodec.encode([.normal])
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
            rareRewardRuleVersion: Constants.Gacha.creditRuleVersion,
            rareRewardParticipated: true,
            rareRewardCreditedGrams: 250,
            rareRewardOutcomesRawValue: RareRewardOutcomeCodec.encode([.prism])
        )
        context.insert(firstSession)
        context.insert(laterSession)
        try context.save()

        XCTAssertEqual(
            FocusSyncPolicy.supersededSessionIDs(
                from: [laterTimer.policySnapshot, firstTimer.policySnapshot]
            ),
            Set<UUID>()
        )
        try SeedData.bootstrap(context: context)

        var remaining = try context.fetch(FetchDescriptor<StudySession>())
            .sorted { $0.startAt < $1.startAt }
        XCTAssertEqual(remaining.map(\.id), [firstID, laterID])
        XCTAssertEqual(remaining[0].effectiveSource, .timer)
        XCTAssertEqual(remaining[1].effectiveSource, .timer)
        XCTAssertEqual(remaining[1].pebbleKind, .prism)
        XCTAssertEqual(remaining.map(\.rareRewardParticipated), [true, true])
        XCTAssertEqual(remaining.flatMap(\.effectiveRareRewardOutcomes), [
            .normal,
            .prism
        ])
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<GachaState>()).first?.sinceLastGold,
            2
        )
        XCTAssertEqual(
            StrataMath.totalGrams(
                sessions: remaining,
                aggregates: try context.fetch(FetchDescriptor<AggregatePebble>())
            ),
            500
        )

        // Active-timer recovery may still choose one canonical timer, but once
        // two different completion UUIDs exist neither is retroactively
        // demoted. The server rare ledger serializes both unique receipts.
        try SeedData.bootstrap(context: context)
        remaining = try context.fetch(FetchDescriptor<StudySession>())
            .sorted { $0.startAt < $1.startAt }
        XCTAssertEqual(remaining.map(\.id), [firstID, laterID])
        XCTAssertEqual(remaining.map(\.effectiveSource), [.timer, .timer])
        XCTAssertEqual(remaining[1].pebbleKind, .prism)
        XCTAssertEqual(
            StrataMath.totalGrams(
                sessions: remaining,
                aggregates: try context.fetch(FetchDescriptor<AggregatePebble>())
            ),
            500
        )
    }
}
