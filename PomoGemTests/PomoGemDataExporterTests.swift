import Foundation
import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class PomoGemDataExporterTests: XCTestCase {
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PomoGemDataExportProgress] = []

        func append(_ value: PomoGemDataExportProgress) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        func snapshot() -> [PomoGemDataExportProgress] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

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
            "PomoGemDataExporterTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func testVersionedExportStreamsExportableStoredModelsBeyondOneBatch() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let epochID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let subjectID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let subjectSyncRecordID = UUID(uuidString: "21000000-0000-0000-0000-000000000001")!
        let subjectMutationID = UUID(uuidString: "22000000-0000-0000-0000-000000000001")!
        let subject = Subject(
            id: subjectID,
            name: "社外秘プロジェクト",
            colorHex: "#12A0D0",
            sortOrder: 7,
            isArchived: true,
            deletedAt: instant.addingTimeInterval(120),
            createdAt: instant,
            syncRecordID: subjectSyncRecordID,
            contentRevision: 9,
            contentMutationID: subjectMutationID
        )
        context.insert(subject)

        let sessionCount = PomoGemDataExportPolicy.batchSize * 2 + 8
        var sessionIDs: [UUID] = []
        for index in 0 ..< sessionCount {
            let id = UUID(uuidString: String(
                format: "30000000-0000-0000-0000-%012d",
                index
            ))!
            sessionIDs.append(id)
            let session = StudySession(
                id: id,
                subject: subject,
                startAt: instant,
                endAt: instant.addingTimeInterval(1_500),
                seconds: 1_500,
                source: index.isMultiple(of: 3) ? .manual : .timer,
                pebbleKind: index == 0 ? .prism : .normal,
                grams: 250,
                deviceDayKey: "2023-11-14",
                isBaked: index.isMultiple(of: 2),
                rareRewardRuleVersion: 2,
                rareRewardParticipated: true,
                rareRewardCreditedGrams: 250,
                rareRewardOutcomesRawValue: index == 0 ? "prism" : "",
                dataEpochID: epochID,
                syncRecordID: UUID(uuidString: String(
                    format: "31000000-0000-0000-0000-%012d",
                    index
                ))!
            )
            if index == 0 {
                // Unsupported synchronized/legacy rows stay available in the
                // raw export even though user-visible projections quarantine
                // them through StudySessionIntegrityPolicy.
                session.seconds = Int.max
                session.grams = Int.max
            }
            context.insert(session)
        }

        let achievementSyncRecordID = UUID(
            uuidString: "41000000-0000-0000-0000-000000000001"
        )!
        let achievementDeletionID = UUID(
            uuidString: "42000000-0000-0000-0000-000000000001"
        )!
        let achievementRestoreID = UUID(
            uuidString: "42000000-0000-0000-0000-000000000002"
        )!
        context.insert(AchievementStone(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
            subject: subject,
            kind: .workMilestone,
            note: "公開前の成果メモ",
            achievedAt: instant,
            createdAt: instant,
            dataEpochID: epochID,
            revision: 3,
            deletedAt: instant.addingTimeInterval(60),
            deletionMutationID: achievementDeletionID,
            deletionRevision: 3,
            restoredDeletionMutationID: achievementRestoreID,
            updatedAt: instant.addingTimeInterval(60),
            syncRecordID: achievementSyncRecordID
        ))
        context.insert(AggregatePebble(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            createdAt: instant,
            level: 2,
            pebbleCount: 10,
            childAggregateCount: 1,
            grams: 2_500,
            measuredPebbleCount: 8,
            manualPebbleCount: 2,
            goldPebbleCount: 1,
            prismPebbleCount: 1,
            colorMixJSON: "[{\"hex\":\"#12A0D0\",\"frac\":1}]",
            subjectMixJSON: "[{\"name\":\"社外秘プロジェクト\",\"colorHex\":\"#12A0D0\",\"pebbleCount\":10}]",
            periodStart: instant,
            periodEnd: instant.addingTimeInterval(1_500),
            sessionIDs: Array(sessionIDs.prefix(10)),
            childAggregateIDs: [UUID(uuidString: "50000000-0000-0000-0000-000000000002")!],
            parentAggregateID: UUID(uuidString: "50000000-0000-0000-0000-000000000003")!,
            dataEpochID: epochID
        ))
        context.insert(Stratum(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!,
            bakedAt: instant,
            pebbleCount: 10,
            heightPt: 12.5,
            colorMixJSON: "[{\"hex\":\"#12A0D0\",\"frac\":1}]",
            monthLabel: "2023-11",
            grams: 2_500,
            // The legacy summary's positive export case has ten supported
            // timers; unsupported raw rows above remain serialized separately.
            sessionIDs: Array(sessionIDs.enumerated().filter { !$0.offset.isMultiple(of: 3) }.prefix(10).map(\.element)),
            dataEpochID: epochID
        ))
        context.insert(Bedrock(hours: 40, importedAt: instant, dataEpochID: epochID))
        context.insert(GachaState(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
            sinceLastGold: 8,
            rewardCreditGrams: 9_999,
            dataEpochID: epochID
        ))
        let prefsSyncRecordID = UUID(
            uuidString: "81000000-0000-0000-0000-000000000001"
        )!
        let prefs = Prefs(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000001")!,
            manualDayKey: "2023-11-14",
            manualUsedToday: 2,
            soundOn: false,
            hapticsOn: false,
            timerCompletionSoundRawValue: TimerCompletionSound.bright.rawValue,
            timerCompletionHapticRawValue: TimerCompletionHaptic.strong.rawValue,
            rareRewardModeRawValue: RareRewardMode.quiet.rawValue,
            rareRewardModeUpdatedAt: instant,
            reminderEnabled: true,
            reminderHour: 6,
            reminderMinute: 45,
            shareIncludesManual: true,
            showsThemeNameExternally: true,
            isPro: true,
            keepScreenAwake: false,
            preferredFocusMinutes: 47,
            timerDisplayModeRawValue: TimerDisplayMode.filledDial.rawValue,
            hasCompletedOnboarding: true,
            usagePurposeRawValue: UsagePurpose.work.rawValue,
            usagePurposeUpdatedAt: instant,
            hasEverImportedBedrock: true,
            hasCompletedInitialSubjectSeed: true,
            activityEpochID: epochID,
            syncRecordID: prefsSyncRecordID,
            settingsWriterID: "account-device-writer"
        )
        let preferenceMutationIDs = (1...13).map { index in
            UUID(uuidString: String(
                format: "82000000-0000-0000-0000-%012d",
                index
            ))!
        }
        prefs.soundRevision = 11
        prefs.soundMutationID = preferenceMutationIDs[0]
        prefs.hapticsRevision = 12
        prefs.hapticsMutationID = preferenceMutationIDs[1]
        prefs.rareRewardRevision = 13
        prefs.rareRewardMutationID = preferenceMutationIDs[2]
        prefs.reminderEnabledRevision = 14
        prefs.reminderEnabledMutationID = preferenceMutationIDs[3]
        prefs.reminderTimeRevision = 15
        prefs.reminderTimeMutationID = preferenceMutationIDs[4]
        prefs.shareIncludesManualRevision = 16
        prefs.shareIncludesManualMutationID = preferenceMutationIDs[5]
        prefs.externalThemeRevision = 17
        prefs.externalThemeMutationID = preferenceMutationIDs[6]
        prefs.keepScreenAwakeRevision = 18
        prefs.keepScreenAwakeMutationID = preferenceMutationIDs[7]
        prefs.preferredFocusMinutesRevision = 19
        prefs.preferredFocusMinutesMutationID = preferenceMutationIDs[8]
        prefs.preferredFocusSeconds = 47 * 60 + 35
        prefs.preferredFocusSecondsMutationID = preferenceMutationIDs[8]
        prefs.timerDisplayModeRevision = 20
        prefs.timerDisplayModeMutationID = preferenceMutationIDs[9]
        prefs.usagePurposeRevision = 21
        prefs.usagePurposeMutationID = preferenceMutationIDs[10]
        prefs.timerCompletionSoundRevision = 22
        prefs.timerCompletionSoundMutationID = preferenceMutationIDs[11]
        prefs.timerCompletionHapticRevision = 23
        prefs.timerCompletionHapticMutationID = preferenceMutationIDs[12]
        context.insert(prefs)
        context.insert(ActivityResetMarker(
            id: UUID(uuidString: "90000000-0000-0000-0000-000000000001")!,
            epochID: epochID,
            sequence: 4,
            resetAt: instant,
            writerDeviceID: "random-reset-device-id"
        ))

        let timerSessionID = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: instant, sessionID: timerSessionID)
        let envelope = FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(
                id: subjectID,
                name: subject.name,
                colorHex: subject.colorHex
            ),
            clockAnchor: nil,
            pendingCompletion: nil,
            savedAt: instant,
            dataEpochID: epochID
        )
        context.insert(try SyncedFocusTimer(
            id: UUID(uuidString: "B0000000-0000-0000-0000-000000000001")!,
            sessionID: timerSessionID,
            status: .running,
            payload: FocusCloudPayload(envelope: envelope),
            updatedAt: instant,
            revision: 2,
            ownershipSequence: 3,
            writerDeviceID: "random-timer-device-id"
        ))
        context.insert(FocusTimerDeviceClaim(
            id: UUID(uuidString: "C0000000-0000-0000-0000-000000000001")!,
            sessionID: timerSessionID,
            deviceID: "random-claim-device-id",
            sequence: 3,
            claimedAt: instant,
            releasedAt: instant.addingTimeInterval(30),
            dataEpochID: epochID,
            syncRecordID: UUID(
                uuidString: "C1000000-0000-0000-0000-000000000001"
            )!
        ))
        let rareMigration = RareRewardLedgerMigration.legacy(
            dataEpochID: epochID,
            totalCreditedGrams: 0,
            sinceLastGold: 0
        )
        let rareSubmission = RareRewardLedgerSubmission(
            epochID: epochID,
            sessionID: timerSessionID,
            source: .timer,
            completedSeconds: 1_500,
            completedGrams: 250,
            mode: .quiet
        )
        context.insert(RareRewardPendingCommit(
            id: timerSessionID,
            dataEpochID: epochID,
            submission: rareSubmission,
            migration: rareMigration,
            createdAt: instant
        ))
        context.insert(RareRewardLedgerCursor(
            id: epochID,
            dataEpochID: epochID,
            migration: rareMigration,
            receipt: RareRewardLedgerReceipt(
                epochID: epochID,
                sessionID: timerSessionID,
                submissionFingerprint: rareSubmission.fingerprint,
                participated: true,
                nonparticipationReason: nil,
                acceptedGrams: 250,
                firstOrdinal: 0,
                ordinalCount: 1,
                outcomes: [.normal],
                revisionBefore: 0,
                revisionAfter: 1,
                totalCreditedGramsAfter: 250,
                creditRemainderGramsAfter: 0,
                sinceLastGoldAfter: 1
            ),
            updatedAt: instant
        ))
        try context.save()

        let progress = ProgressRecorder()
        let exportedAt = instant.addingTimeInterval(3_600)
        let worker = PomoGemDataExportWorker(modelContainer: container)
        let result = try await worker.export(
            appInfo: PomoGemDataExportAppInfo(version: "1.2.3", build: "456"),
            exportedAt: exportedAt,
            includesRetainedRareRewardModels: true,
            progress: { progress.append($0) }
        )
        addTeardownBlock {
            try? PomoGemDataExporter.removeExport(at: result.fileURL)
        }

        XCTAssertEqual(result.recordCounts.studySessions, sessionCount)
        XCTAssertEqual(result.recordCounts.total, sessionCount + 11)
        XCTAssertEqual(result.recordCounts.aggregatePebbles, 0, "Missing child membership cannot prove a public summary")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path))

        let data = try Data(contentsOf: result.fileURL)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["format"] as? String, PomoGemDataExportPolicy.format)
        XCTAssertEqual(object["schemaVersion"] as? Int, PomoGemDataExportPolicy.schemaVersion)
        XCTAssertEqual(object["dateEncoding"] as? String, "secondsSince1970")
        XCTAssertEqual(object["binaryEncoding"] as? String, "base64")
        XCTAssertEqual(object["scope"] as? String, "locallyAvailableExternalData")
        XCTAssertEqual(object["excludedSources"] as? [String], ["screenTime"])

        let records = try XCTUnwrap(object["records"] as? [String: Any])
        let expectedCollections: Set<String> = [
            "subjects",
            "studySessions",
            "achievementStones",
            "aggregatePebbles",
            "legacyStrata",
            "legacyBedrocks",
            "gachaStates",
            "preferences",
            "activityResetMarkers",
            "syncedFocusTimers",
            "focusTimerDeviceClaims",
            "rareRewardPendingCommits",
            "rareRewardLedgerCursors"
        ]
        XCTAssertEqual(Set(records.keys), expectedCollections)
        for key in expectedCollections {
            if key == "aggregatePebbles" { continue }
            XCTAssertFalse(try XCTUnwrap(records[key] as? [Any]).isEmpty, key)
        }

        let subjects = try XCTUnwrap(records["subjects"] as? [[String: Any]])
        XCTAssertEqual(subjects.first?["syncRecordID"] as? String, subjectSyncRecordID.uuidString)
        XCTAssertEqual(subjects.first?["contentRevision"] as? Int, 9)
        XCTAssertEqual(subjects.first?["contentMutationID"] as? String, subjectMutationID.uuidString)
        XCTAssertNotNil(subjects.first?["deletedAt"])

        let sessions = try XCTUnwrap(records["studySessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, sessionCount)
        XCTAssertEqual(sessions.first?["id"] as? String, sessionIDs.first?.uuidString)
        XCTAssertEqual(sessions.last?["id"] as? String, sessionIDs.last?.uuidString)
        XCTAssertEqual(sessions.first?["subjectID"] as? String, subjectID.uuidString)
        XCTAssertEqual(sessions.first?["rareRewardOutcomesRawValue"] as? String, "prism")
        XCTAssertEqual(sessions.first?["seconds"] as? Int, Int.max)
        XCTAssertEqual(sessions.first?["grams"] as? Int, Int.max)
        XCTAssertEqual(
            sessions.first?["syncRecordID"] as? String,
            "31000000-0000-0000-0000-000000000000"
        )

        let achievements = try XCTUnwrap(records["achievementStones"] as? [[String: Any]])
        XCTAssertEqual(achievements.first?["note"] as? String, "公開前の成果メモ")
        XCTAssertNotNil(achievements.first?["deletedAt"])
        XCTAssertEqual(
            achievements.first?["syncRecordID"] as? String,
            achievementSyncRecordID.uuidString
        )
        XCTAssertEqual(
            achievements.first?["deletionMutationID"] as? String,
            achievementDeletionID.uuidString
        )
        XCTAssertEqual(achievements.first?["deletionRevision"] as? Int, 3)
        XCTAssertEqual(
            achievements.first?["restoredDeletionMutationID"] as? String,
            achievementRestoreID.uuidString
        )
        let preferences = try XCTUnwrap(records["preferences"] as? [[String: Any]])
        let exportedPrefs = try XCTUnwrap(preferences.first)
        XCTAssertNil(exportedPrefs["isPro"])
        XCTAssertEqual(exportedPrefs["legacyIsProIgnored"] as? Bool, false)
        XCTAssertEqual(exportedPrefs["syncRecordID"] as? String, prefsSyncRecordID.uuidString)
        XCTAssertEqual(exportedPrefs["settingsWriterID"] as? String, "account-device-writer")
        XCTAssertEqual(exportedPrefs["preferredFocusMinutes"] as? Int, 47)
        XCTAssertEqual(exportedPrefs["preferredFocusSeconds"] as? Int, 47 * 60 + 35)
        XCTAssertEqual(exportedPrefs["preferredFocusSecondsMutationID"] as? String,
                       preferenceMutationIDs[8].uuidString)
        let stampKeys = [
            "sound", "haptics", "rareReward", "reminderEnabled", "reminderTime",
            "shareIncludesManual", "externalTheme", "keepScreenAwake",
            "preferredFocusMinutes", "timerDisplayMode", "usagePurpose",
            "timerCompletionSound", "timerCompletionHaptic"
        ]
        for (index, key) in stampKeys.enumerated() {
            XCTAssertEqual(exportedPrefs["\(key)Revision"] as? Int, index + 11, key)
            XCTAssertEqual(
                exportedPrefs["\(key)MutationID"] as? String,
                preferenceMutationIDs[index].uuidString,
                key
            )
        }
        XCTAssertEqual(
            exportedPrefs["timerCompletionSoundRawValue"] as? String,
            TimerCompletionSound.bright.rawValue
        )
        XCTAssertEqual(
            exportedPrefs["timerCompletionHapticRawValue"] as? String,
            TimerCompletionHaptic.strong.rawValue
        )
        XCTAssertEqual(
            exportedPrefs["timerDisplayModeRawValue"] as? String,
            TimerDisplayMode.filledDial.rawValue
        )
        let timers = try XCTUnwrap(records["syncedFocusTimers"] as? [[String: Any]])
        XCTAssertFalse((timers.first?["payloadDataBase64"] as? String ?? "").isEmpty)
        XCTAssertEqual(timers.first?["writerDeviceID"] as? String, "random-timer-device-id")
        let claims = try XCTUnwrap(records["focusTimerDeviceClaims"] as? [[String: Any]])
        XCTAssertEqual(
            claims.first?["syncRecordID"] as? String,
            "C1000000-0000-0000-0000-000000000001"
        )

        let progressValues = progress.snapshot()
        XCTAssertTrue(progressValues.contains {
            if case .writing(collectionName: "集中記録") = $0.phase {
                return $0.completedRecords >= PomoGemDataExportPolicy.batchSize
            }
            return false
        })
        XCTAssertEqual(progressValues.last?.phase, .finishing)
    }

    func testExternalExportExcludesScreenTimeAndUnverifiedSummariesWithoutChangingPersonalData() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        func record(source: SessionSource, seconds: Int, offset: TimeInterval, name: String) -> StudySession {
            let end = instant.addingTimeInterval(offset)
            let value = StudySession(
                startAt: end.addingTimeInterval(-Double(seconds)), endAt: end,
                seconds: seconds, source: source,
                deviceDayKey: FairnessPolicy.deviceDayKey(for: end),
                subjectNameSnapshot: name,
                subjectColorHexSnapshot: source == .timer ? "#327AB8" : "#28A475"
            )
            context.insert(value)
            return value
        }
        let timer = record(source: .timer, seconds: 1_500, offset: 0, name: "Public timer theme")
        let manual = record(source: .manual, seconds: 1_800, offset: 3_600, name: "Public manual theme")
        let additionalTimers = (1...8).map { index in
            record(source: .timer, seconds: 1_500, offset: -Double(index) * 2_000, name: "Public timer theme")
        }
        let publicRows = [timer, manual] + additionalTimers
        let privateRow = record(source: .screenTime, seconds: 600, offset: 99_999, name: "PRIVATE_USAGE_SNAPSHOT")
        let compatiblePrivate = record(source: .manual, seconds: 600, offset: -99_999, name: "PRIVATE_COMPATIBILITY_SNAPSHOT")
        let conflictingPublicCopy = record(source: .timer, seconds: 1_500, offset: 99_999, name: "PRIVATE_CONFLICT_SNAPSHOT")
        conflictingPublicCopy.id = privateRow.id
        func aggregate(members: [UUID], count: Int, childIDs: [UUID] = []) -> AggregatePebble {
            let value = AggregatePebble(
                createdAt: privateRow.endAt, level: 8, pebbleCount: count,
                childAggregateCount: childIDs.count, grams: 99_999,
                measuredPebbleCount: count,
                colorMixJSON: "[{\"hex\":\"#FF00F3\",\"fraction\":1}]",
                subjectMixJSON: "[{\"name\":\"PRIVATE_SUMMARY_SNAPSHOT\",\"colorHex\":\"#FF00F3\",\"pebbleCount\":999}]",
                periodStart: compatiblePrivate.startAt, periodEnd: privateRow.endAt,
                sessionIDs: members, childAggregateIDs: childIDs
            )
            context.insert(value)
            return value
        }
        let safe = aggregate(members: publicRows.map(\.id), count: 10)
        let mixed = aggregate(members: [timer.id, privateRow.id], count: 2)
        let unknown = aggregate(members: [], count: 999)
        let parent = aggregate(members: [], count: 4, childIDs: [safe.id, mixed.id])
        let safeLegacy = Stratum(
            bakedAt: privateRow.endAt, pebbleCount: 10, heightPt: 99_999,
            colorMixJSON: "[{\"hex\":\"#FF00F3\",\"fraction\":1}]",
            monthLabel: "PRIVATE_MONTH_SNAPSHOT", grams: 99_999,
            sessionIDs: publicRows.map(\.id)
        )
        let privateLegacy = Stratum(
            bakedAt: privateRow.endAt, pebbleCount: 2, heightPt: 99_999,
            colorMixJSON: "[]", monthLabel: "PRIVATE_MONTH_SNAPSHOT", grams: 99_999,
            sessionIDs: [manual.id, privateRow.id]
        )
        let unknownLegacy = Stratum(
            bakedAt: privateRow.endAt, pebbleCount: 999, heightPt: 99_999,
            colorMixJSON: "[]", monthLabel: "PRIVATE_MONTH_SNAPSHOT", grams: 99_999
        )
        for value in [safeLegacy, privateLegacy, unknownLegacy] { context.insert(value) }
        try context.save()

        let result = try await PomoGemDataExportWorker(modelContainer: container).export(
            appInfo: .init(version: "1.1.0", build: "10"), exportedAt: instant.addingTimeInterval(7_200)
        )
        addTeardownBlock { try? PomoGemDataExporter.removeExport(at: result.fileURL) }
        let data = try Data(contentsOf: result.fileURL)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(document["records"] as? [String: Any])
        let sessions = try XCTUnwrap(records["studySessions"] as? [[String: Any]])
        XCTAssertEqual(result.recordCounts.studySessions, 10)
        XCTAssertEqual(Set(sessions.compactMap { $0["id"] as? String }), Set(publicRows.map { $0.id.uuidString }))
        XCTAssertEqual(Set(sessions.compactMap { $0["source"] as? String }), Set(["timer", "manual"]))
        XCTAssertEqual(sessions.compactMap { $0["grams"] as? Int }.reduce(0, +), 2_550)
        for privateID in [privateRow.id, compatiblePrivate.id, mixed.id, unknown.id, parent.id, privateLegacy.id, unknownLegacy.id] {
            XCTAssertFalse(text.contains(privateID.uuidString))
        }
        for marker in ["PRIVATE_USAGE_SNAPSHOT", "PRIVATE_COMPATIBILITY_SNAPSHOT", "PRIVATE_CONFLICT_SNAPSHOT", "PRIVATE_SUMMARY_SNAPSHOT", "PRIVATE_MONTH_SNAPSHOT", "#FF00F3"] {
            XCTAssertFalse(text.contains(marker), marker)
        }
        let aggregates = try XCTUnwrap(records["aggregatePebbles"] as? [[String: Any]])
        XCTAssertEqual(aggregates.count, 1)
        XCTAssertEqual(aggregates.first?["id"] as? String, safe.id.uuidString)
        XCTAssertEqual(aggregates.first?["grams"] as? Int, 2_550)
        XCTAssertEqual(aggregates.first?["createdAt"] as? Double, manual.endAt.timeIntervalSince1970)
        XCTAssertEqual(aggregates.first?["periodStart"] as? Double, publicRows.map(\.startAt).min()?.timeIntervalSince1970)
        XCTAssertEqual(aggregates.first?["childAggregateCount"] as? Int, 0)
        XCTAssertNil(aggregates.first?["parentAggregateID"])
        let strata = try XCTUnwrap(records["legacyStrata"] as? [[String: Any]])
        XCTAssertEqual(strata.count, 1)
        XCTAssertEqual(strata.first?["grams"] as? Int, 2_550)
        XCTAssertEqual(strata.first?["bakedAt"] as? Double, manual.endAt.timeIntervalSince1970)
        XCTAssertNil(strata.first?["heightPt"], "Personal pile geometry is not an external field")

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StudySession>()), 13)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AggregatePebble>()), 4)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Stratum>()), 3)
        XCTAssertEqual(privateRow.effectiveSource, .screenTime)
        XCTAssertEqual(compatiblePrivate.effectiveSource, .screenTime)
        XCTAssertEqual(privateRow.subjectNameSnapshot, "PRIVATE_USAGE_SNAPSHOT")
        XCTAssertEqual(safe.grams, 99_999, "The external projection must not rewrite personal totals")
        XCTAssertEqual(safeLegacy.heightPt, 99_999)
    }

    func testCleanupOnlyRemovesOwnedExportDirectory() async throws {
        let container = try makeContainer()
        let worker = PomoGemDataExportWorker(modelContainer: container)
        let result = try await worker.export(
            appInfo: PomoGemDataExportAppInfo(version: "test", build: "test")
        )
        let directory = result.fileURL.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.fileURL.path))

        try PomoGemDataExporter.removeExport(at: result.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        let unrelatedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomogem-exporter-unrelated-\(UUID().uuidString).txt")
        try Data("keep".utf8).write(to: unrelatedURL)
        addTeardownBlock { try? FileManager.default.removeItem(at: unrelatedURL) }
        try PomoGemDataExporter.removeExport(at: unrelatedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }
}
