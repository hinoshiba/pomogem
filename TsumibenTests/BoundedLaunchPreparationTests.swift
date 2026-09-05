import SwiftData
import XCTest
@testable import Tsumiben

@MainActor
final class BoundedLaunchPreparationTests: XCTestCase {
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

    func testLatestResetFetchIsLimitedAndMatchesEveryPolicyTieBreak() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let resetAt = Date(timeIntervalSince1970: 1_700_000_000)
        let markers = [
            ActivityResetMarker(
                id: uuid("00000000-0000-0000-0000-000000000001"),
                epochID: uuid("00000000-0000-0000-0000-000000000011"),
                sequence: 9,
                resetAt: resetAt.addingTimeInterval(-1),
                writerDeviceID: "z"
            ),
            ActivityResetMarker(
                id: uuid("00000000-0000-0000-0000-000000000002"),
                epochID: uuid("00000000-0000-0000-0000-000000000012"),
                sequence: 8,
                resetAt: resetAt,
                writerDeviceID: "z"
            ),
            ActivityResetMarker(
                id: uuid("00000000-0000-0000-0000-000000000003"),
                epochID: uuid("00000000-0000-0000-0000-000000000013"),
                sequence: 9,
                resetAt: resetAt,
                writerDeviceID: "a"
            ),
            ActivityResetMarker(
                id: uuid("00000000-0000-0000-0000-000000000004"),
                epochID: uuid("00000000-0000-0000-0000-000000000014"),
                sequence: 9,
                resetAt: resetAt,
                writerDeviceID: "z"
            ),
            ActivityResetMarker(
                id: uuid("00000000-0000-0000-0000-000000000005"),
                epochID: uuid("00000000-0000-0000-0000-000000000014"),
                sequence: 9,
                resetAt: resetAt,
                writerDeviceID: "z"
            )
        ]
        markers.reversed().forEach(context.insert)
        try context.save()

        let descriptor = BoundedLaunchPreparation.latestResetMarkerDescriptor()
        XCTAssertEqual(descriptor.fetchLimit, 1)
        let fetched = try context.fetch(descriptor)
        let expected = ActivityResetPolicy.currentMarker(
            from: markers.map(\.policySnapshot)
        )

        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.policySnapshot, expected)
        XCTAssertEqual(fetched.first?.id, markers.last?.id)
    }

    func testColdLaunchFindsWinnerBelowUnsupportedSequenceAndQuarantinesItsEpoch() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let validEpochID = uuid("01000000-0000-0000-0000-000000000001")
        let corruptEpochID = uuid("01000000-0000-0000-0000-000000000002")
        let valid = ActivityResetMarker(
            epochID: validEpochID,
            sequence: 1,
            resetAt: now.addingTimeInterval(-60),
            writerDeviceID: "valid-device"
        )
        let corrupt = ActivityResetMarker(
            epochID: corruptEpochID,
            sequence: ActivityResetPolicy.maximumSupportedSequence + 1,
            resetAt: now.addingTimeInterval(60 * 60 * 24 * 365 * 100),
            writerDeviceID: "corrupt"
        )
        context.insert(valid)
        context.insert(corrupt)
        try context.save()

        let descriptor = BoundedLaunchPreparation.latestResetMarkerDescriptor(
            now: now
        )
        let fetched = try context.fetch(descriptor)
        XCTAssertEqual(descriptor.fetchLimit, 1)
        XCTAssertEqual(fetched.map(\.epochID), [validEpochID])

        let result = try BoundedLaunchPreparation.prepare(
            context: context,
            localFocusEpochID: corruptEpochID,
            hasLocalFocus: true,
            pendingCompletionID: nil,
            now: now
        )

        XCTAssertEqual(result.currentMarker?.epochID, validEpochID)
        XCTAssertEqual(result.localFocusEpochState, .awaitingMarker)
        XCTAssertEqual(result.localFocusDisposition, .quarantineAwaitingMarker)
        XCTAssertEqual(result.fetchAudit.latestResetMarkerRows, 1)
        XCTAssertEqual(result.fetchAudit.matchingResetMarkerRows, 0)
        XCTAssertLessThanOrEqual(result.fetchAudit.maximumRowsReturnedByAnyFetch, 1)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<ActivityResetMarker>()),
            2,
            "quarantine must preserve an unsupported marker for diagnosis"
        )
    }

    func testPreparationCreatesOwnedPrefsWithoutRewritingForeignRows() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let epochID = uuid("10000000-0000-0000-0000-000000000001")
        let unknownEpochID = uuid("20000000-0000-0000-0000-000000000001")
        context.insert(ActivityResetMarker(
            epochID: epochID,
            sequence: 1,
            resetAt: .now,
            writerDeviceID: "device"
        ))

        let currentPrefs = Prefs(
            id: uuid("30000000-0000-0000-0000-000000000001"),
            hasCompletedOnboarding: true,
            activityEpochID: epochID
        )
        let unknownPrefs = Prefs(
            id: uuid("30000000-0000-0000-0000-000000000002"),
            hasCompletedOnboarding: true,
            activityEpochID: unknownEpochID
        )
        let currentGacha = GachaState(
            id: uuid("40000000-0000-0000-0000-000000000001"),
            sinceLastGold: 17,
            rewardCreditGrams: 350,
            dataEpochID: epochID
        )
        let unknownGacha = GachaState(
            id: uuid("40000000-0000-0000-0000-000000000002"),
            sinceLastGold: 99,
            dataEpochID: unknownEpochID
        )
        [currentPrefs, unknownPrefs].forEach(context.insert)
        [currentGacha, unknownGacha].forEach(context.insert)

        // If cold preparation accidentally reintroduced the historical gacha
        // fold, this eligible gold would change the preserved counter.
        context.insert(makeSession(
            id: uuid("50000000-0000-0000-0000-000000000001"),
            epochID: epochID,
            kind: .gold
        ))
        try context.save()

        let result = try BoundedLaunchPreparation.prepare(
            context: context,
            localFocusEpochID: nil,
            hasLocalFocus: false,
            pendingCompletionID: nil
        )

        XCTAssertEqual(result.canonicalPrefs.id, BoundedLaunchPreparation.canonicalPrefsID)
        XCTAssertEqual(result.canonicalPrefs.activityEpochID, epochID)
        XCTAssertEqual(
            result.canonicalPrefs.settingsWriterID,
            FocusDeviceIdentity.current()
        )
        XCTAssertEqual(result.canonicalGacha.id, BoundedLaunchPreparation.canonicalGachaID)
        XCTAssertEqual(result.canonicalGacha.dataEpochID, epochID)
        XCTAssertEqual(result.canonicalGacha.sinceLastGold, 17)
        XCTAssertEqual(result.canonicalGacha.rewardCreditGrams, 350)
        XCTAssertEqual(result.canonicalGacha.rewardCreditRemainderGrams, 100)
        XCTAssertTrue(result.hasSyncedUsageEvidence)
        XCTAssertEqual(result.fetchAudit.prefsOwnedRows, 0)
        XCTAssertEqual(result.fetchAudit.prefsPhysicalRows, 2)
        XCTAssertEqual(result.fetchAudit.maximumRowsReturnedByAnyFetch, 2)
        XCTAssertEqual(result.deferredMaintenanceReasons, [
            .prefsSingletonCreated,
            .gachaSingletonCanonicalized
        ])

        XCTAssertEqual(currentPrefs.id, uuid("30000000-0000-0000-0000-000000000001"))
        XCTAssertEqual(currentPrefs.activityEpochID, epochID)
        XCTAssertEqual(currentPrefs.settingsWriterID, "")
        XCTAssertEqual(unknownPrefs.id, uuid("30000000-0000-0000-0000-000000000002"))
        XCTAssertEqual(unknownPrefs.activityEpochID, unknownEpochID)
        XCTAssertEqual(unknownPrefs.settingsWriterID, "")
        XCTAssertEqual(unknownGacha.id, uuid("40000000-0000-0000-0000-000000000002"))
        XCTAssertEqual(unknownGacha.sinceLastGold, 99)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Prefs>()).count, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<GachaState>()).count, 2)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Subject>()).isEmpty)
    }

    func testOnboardingEvidenceUsesCurrentEpochAndIgnoresUnknownRows() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let currentEpochID = uuid("60000000-0000-0000-0000-000000000001")
        let unknownEpochID = uuid("60000000-0000-0000-0000-000000000002")
        context.insert(ActivityResetMarker(
            epochID: currentEpochID,
            sequence: 2,
            resetAt: .now,
            writerDeviceID: "device"
        ))

        for index in 0 ..< 128 {
            context.insert(makeSession(
                id: UUID(),
                epochID: unknownEpochID,
                endAt: Date(timeIntervalSince1970: Double(10_000 + index))
            ))
        }
        try context.save()

        let quarantinedOnly = try BoundedLaunchPreparation.prepare(
            context: context,
            localFocusEpochID: nil,
            hasLocalFocus: false,
            pendingCompletionID: nil
        )
        XCTAssertFalse(quarantinedOnly.hasSyncedUsageEvidence)
        XCTAssertEqual(quarantinedOnly.fetchAudit.onboardingSessionRows, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<StudySession>()).count, 128)

        context.insert(makeSession(
            id: UUID(),
            epochID: currentEpochID,
            endAt: Date(timeIntervalSince1970: 1)
        ))
        try context.save()
        let withOldCurrentEvidence = try BoundedLaunchPreparation.prepare(
            context: context,
            localFocusEpochID: nil,
            hasLocalFocus: false,
            pendingCompletionID: nil
        )

        XCTAssertTrue(withOldCurrentEvidence.hasSyncedUsageEvidence)
        XCTAssertEqual(withOldCurrentEvidence.fetchAudit.onboardingSessionRows, 1)
        XCTAssertLessThanOrEqual(
            withOldCurrentEvidence.fetchAudit.maximumRowsReturnedByAnyFetch,
            1
        )
    }

    func testOnboardingPreferenceEvidenceSurvivesActivityEpochReset() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let currentEpochID = uuid("61000000-0000-0000-0000-000000000001")
        let previousEpochID = uuid("61000000-0000-0000-0000-000000000002")
        context.insert(ActivityResetMarker(
            epochID: currentEpochID,
            sequence: 2,
            resetAt: .now,
            writerDeviceID: "device"
        ))
        context.insert(Prefs(
            id: uuid("61000000-0000-0000-0000-000000000003"),
            hasCompletedOnboarding: true,
            activityEpochID: previousEpochID
        ))
        try context.save()

        let result = try BoundedLaunchPreparation.prepare(
            context: context,
            localFocusEpochID: nil,
            hasLocalFocus: false,
            pendingCompletionID: nil
        )

        XCTAssertTrue(result.hasSyncedUsageEvidence)
        XCTAssertEqual(result.fetchAudit.onboardingPrefsRows, 1)
        XCTAssertEqual(result.canonicalPrefs.activityEpochID, currentEpochID)
        XCTAssertFalse(result.canonicalPrefs.hasCompletedOnboarding)
    }

    func testOnboardingEvidencePagesPastUnsupportedNewestCandidates() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let invalidCount =
            BoundedLaunchPreparation.QueryContract.onboardingSessionPageLimit + 7

        for index in 0 ..< invalidCount {
            let endAt = now.addingTimeInterval(-Double(index + 1))
            let invalid = makeSession(id: UUID(), epochID: nil, endAt: endAt)
            invalid.startAt = endAt.addingTimeInterval(-5_400)
            invalid.seconds = 5_400
            invalid.grams = StudySession.grams(for: 5_400)
            invalid.source = .manual
            XCTAssertFalse(StudySessionIntegrityPolicy.isSupported(
                invalid,
                relativeTo: now
            ))
            context.insert(invalid)
        }
        let supported = makeSession(
            id: UUID(),
            epochID: nil,
            endAt: now.addingTimeInterval(-10_000)
        )
        context.insert(supported)
        try context.save()

        let result = try BoundedLaunchPreparation.prepare(
            context: context,
            localFocusEpochID: nil,
            hasLocalFocus: false,
            pendingCompletionID: nil,
            now: now
        )

        XCTAssertTrue(result.hasSyncedUsageEvidence)
        XCTAssertEqual(result.fetchAudit.onboardingSessionRows, 1)
        XCTAssertEqual(
            result.fetchAudit.onboardingSessionCandidateRowsScanned,
            invalidCount + 1
        )
        XCTAssertEqual(result.fetchAudit.onboardingSessionFetches, 2)
        XCTAssertEqual(
            result.fetchAudit.onboardingSessionMaximumPageRows,
            BoundedLaunchPreparation.QueryContract.onboardingSessionPageLimit
        )
        XCTAssertFalse(result.fetchAudit.onboardingSessionScanReachedLimit)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<StudySession>()),
            invalidCount + 1,
            "integrity filtering must preserve every raw synchronized row"
        )
    }

    func testOnboardingSessionEvidenceScanStopsAtExplicitHardCap() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rowCount =
            BoundedLaunchPreparation.QueryContract.onboardingSessionMaximumRows + 1

        for index in 0 ..< rowCount {
            let endAt = now.addingTimeInterval(-Double(index + 1))
            let invalid = makeSession(id: UUID(), epochID: nil, endAt: endAt)
            invalid.startAt = endAt.addingTimeInterval(-5_400)
            invalid.seconds = 5_400
            invalid.grams = StudySession.grams(for: 5_400)
            invalid.source = .manual
            context.insert(invalid)
        }
        try context.save()

        let result = try BoundedLaunchPreparation.prepare(
            context: context,
            localFocusEpochID: nil,
            hasLocalFocus: false,
            pendingCompletionID: nil,
            now: now
        )

        XCTAssertFalse(result.hasSyncedUsageEvidence)
        XCTAssertEqual(result.fetchAudit.onboardingSessionRows, 0)
        XCTAssertEqual(
            result.fetchAudit.onboardingSessionCandidateRowsScanned,
            BoundedLaunchPreparation.QueryContract.onboardingSessionMaximumRows
        )
        XCTAssertEqual(
            result.fetchAudit.onboardingSessionFetches,
            BoundedLaunchPreparation.QueryContract.onboardingSessionMaximumPages
        )
        XCTAssertEqual(
            result.fetchAudit.onboardingSessionMaximumPageRows,
            BoundedLaunchPreparation.QueryContract.onboardingSessionPageLimit
        )
        XCTAssertTrue(result.fetchAudit.onboardingSessionScanReachedLimit)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<StudySession>()),
            rowCount
        )
    }

    func testPendingCompletionUsesExactIDAndRetiresOnlyAfterMaterialization() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let oldEpochID = uuid("70000000-0000-0000-0000-000000000001")
        let currentEpochID = uuid("70000000-0000-0000-0000-000000000002")
        let unknownEpochID = uuid("70000000-0000-0000-0000-000000000003")
        let pendingID = uuid("70000000-0000-0000-0000-000000000004")
        context.insert(ActivityResetMarker(
            epochID: oldEpochID,
            sequence: 1,
            resetAt: Date(timeIntervalSince1970: 1),
            writerDeviceID: "device"
        ))
        context.insert(ActivityResetMarker(
            epochID: currentEpochID,
            sequence: 2,
            resetAt: Date(timeIntervalSince1970: 2),
            writerDeviceID: "device"
        ))
        for _ in 0 ..< 128 {
            context.insert(makeSession(id: UUID(), epochID: currentEpochID))
        }
        context.insert(makeSession(id: pendingID, epochID: unknownEpochID))
        try context.save()

        let notMaterialized = try BoundedLaunchPreparation.prepare(
            context: context,
            localFocusEpochID: currentEpochID,
            hasLocalFocus: true,
            pendingCompletionID: pendingID
        )
        XCTAssertEqual(notMaterialized.localFocusEpochState, .current)
        XCTAssertEqual(notMaterialized.pendingCompletionMaterialized, false)
        XCTAssertEqual(notMaterialized.localFocusDisposition, .present)
        XCTAssertEqual(notMaterialized.fetchAudit.pendingCompletionRows, 0)

        let pendingLedgerSession = makeSession(
            id: pendingID,
            epochID: currentEpochID
        )
        pendingLedgerSession.rareRewardRuleVersion = RareRewardLedgerV2.ruleVersion
        pendingLedgerSession.rareRewardParticipated = nil
        context.insert(pendingLedgerSession)
        try context.save()
        let awaitingLedgerReceipt = try BoundedLaunchPreparation.prepare(
            context: context,
            localFocusEpochID: currentEpochID,
            hasLocalFocus: true,
            pendingCompletionID: pendingID
        )
        XCTAssertEqual(awaitingLedgerReceipt.pendingCompletionMaterialized, false)
        XCTAssertEqual(awaitingLedgerReceipt.localFocusDisposition, .present)
        context.delete(pendingLedgerSession)
        try context.save()

        context.insert(makeSession(id: pendingID, epochID: currentEpochID))
        try context.save()
        let materialized = try BoundedLaunchPreparation.prepare(
            context: context,
            localFocusEpochID: currentEpochID,
            hasLocalFocus: true,
            pendingCompletionID: pendingID
        )
        XCTAssertEqual(materialized.pendingCompletionMaterialized, true)
        XCTAssertEqual(
            materialized.localFocusDisposition,
            .retireMaterialized(sessionID: pendingID)
        )
        XCTAssertEqual(materialized.fetchAudit.pendingCompletionRows, 1)
        XCTAssertLessThanOrEqual(
            materialized.fetchAudit.maximumRowsReturnedByAnyFetch,
            BoundedLaunchPreparation.QueryContract.onboardingSessionPageLimit
        )

        let knownStale = try BoundedLaunchPreparation.prepare(
            context: context,
            localFocusEpochID: oldEpochID,
            hasLocalFocus: true,
            pendingCompletionID: pendingID
        )
        XCTAssertEqual(knownStale.localFocusEpochState, .stale)
        XCTAssertEqual(knownStale.localFocusDisposition, .retireStale)
        XCTAssertNil(knownStale.pendingCompletionMaterialized)
        XCTAssertEqual(knownStale.fetchAudit.matchingResetMarkerRows, 1)

        let awaitingMarker = try BoundedLaunchPreparation.prepare(
            context: context,
            localFocusEpochID: unknownEpochID,
            hasLocalFocus: true,
            pendingCompletionID: pendingID
        )
        XCTAssertEqual(awaitingMarker.localFocusEpochState, .awaitingMarker)
        XCTAssertEqual(
            awaitingMarker.localFocusDisposition,
            .quarantineAwaitingMarker
        )
        XCTAssertNil(awaitingMarker.pendingCompletionMaterialized)
        XCTAssertEqual(awaitingMarker.fetchAudit.matchingResetMarkerRows, 0)
        XCTAssertTrue(awaitingMarker.deferredMaintenanceReasons.contains(
            .localFocusAwaitingResetMarker
        ))
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<StudySession>())
                .filter { $0.id == pendingID && $0.dataEpochID == unknownEpochID }
                .count,
            1
        )
    }

    func testEveryColdStartQueryContractIsExplicitlyBounded() {
        XCTAssertEqual(BoundedLaunchPreparation.QueryContract.latestResetMarkerLimit, 1)
        XCTAssertEqual(BoundedLaunchPreparation.QueryContract.singletonLimit, 1)
        XCTAssertEqual(BoundedLaunchPreparation.QueryContract.onboardingEvidenceLimit, 1)
        XCTAssertEqual(
            BoundedLaunchPreparation.QueryContract.onboardingSessionPageLimit,
            32
        )
        XCTAssertEqual(
            BoundedLaunchPreparation.QueryContract.onboardingSessionMaximumPages,
            16
        )
        XCTAssertEqual(
            BoundedLaunchPreparation.QueryContract.onboardingSessionMaximumRows,
            512
        )
        XCTAssertEqual(BoundedLaunchPreparation.QueryContract.pendingCompletionLimit, 1)
        XCTAssertEqual(BoundedLaunchPreparation.QueryContract.matchingResetMarkerLimit, 1)
    }

    func testPrefsConsumerDescriptorKeepsOverflowSentinel() {
        XCTAssertEqual(
            PrefsConsumerPolicy.descriptor().fetchLimit,
            PrefsSyncPolicy.maximumPhysicalRows + 1
        )
    }

    func testPrefsConsumerOverflowFailsClosedForExternalTheme() {
        let values = (0...PrefsSyncPolicy.maximumPhysicalRows).map { index in
            Prefs(
                id: UUID(),
                showsThemeNameExternally: index == 0
            )
        }

        let state = PrefsConsumerPolicy.resolvedState(
            in: values,
            markers: []
        )

        XCTAssertNil(state)
        XCTAssertFalse(state?.showsThemeNameExternally ?? false)
    }

    func testRootPrefsFingerprintObservesIdentityEveryStampAndLifecycle() {
        let prefs = Prefs()
        func assertObserved(
            _ label: String,
            _ mutation: () -> Void,
            line: UInt = #line
        ) {
            let before = PrefsConsumerPolicy.fingerprint(for: prefs)
            mutation()
            XCTAssertNotEqual(
                PrefsConsumerPolicy.fingerprint(for: prefs),
                before,
                label,
                line: line
            )
        }

        assertObserved("syncRecordID") { prefs.syncRecordID = UUID() }
        assertObserved("settingsWriterID") { prefs.settingsWriterID = "device-b" }
        assertObserved("activity epoch") { prefs.activityEpochID = UUID() }
        assertObserved("sound stamp revision") { prefs.soundRevision += 1 }
        assertObserved("sound stamp mutation") { prefs.soundMutationID = UUID() }
        assertObserved("haptics stamp revision") { prefs.hapticsRevision += 1 }
        assertObserved("haptics stamp mutation") { prefs.hapticsMutationID = UUID() }
        assertObserved("completion-sound stamp revision") {
            prefs.timerCompletionSoundRevision += 1
        }
        assertObserved("completion-sound stamp mutation") {
            prefs.timerCompletionSoundMutationID = UUID()
        }
        assertObserved("completion-haptic stamp revision") {
            prefs.timerCompletionHapticRevision += 1
        }
        assertObserved("completion-haptic stamp mutation") {
            prefs.timerCompletionHapticMutationID = UUID()
        }
        assertObserved("completion-sound payload") {
            prefs.timerCompletionSoundRawValue = TimerCompletionSound.soft.rawValue
        }
        assertObserved("completion-haptic payload") {
            prefs.timerCompletionHapticRawValue = TimerCompletionHaptic.strong.rawValue
        }
        assertObserved("rare stamp revision") { prefs.rareRewardRevision += 1 }
        assertObserved("rare stamp mutation") { prefs.rareRewardMutationID = UUID() }
        assertObserved("reminder-enabled stamp revision") {
            prefs.reminderEnabledRevision += 1
        }
        assertObserved("reminder-enabled stamp mutation") {
            prefs.reminderEnabledMutationID = UUID()
        }
        assertObserved("reminder-time stamp revision") {
            prefs.reminderTimeRevision += 1
        }
        assertObserved("reminder-time stamp mutation") {
            prefs.reminderTimeMutationID = UUID()
        }
        assertObserved("share stamp revision") {
            prefs.shareIncludesManualRevision += 1
        }
        assertObserved("share stamp mutation") {
            prefs.shareIncludesManualMutationID = UUID()
        }
        assertObserved("external-theme stamp revision") {
            prefs.externalThemeRevision += 1
        }
        assertObserved("external-theme stamp mutation") {
            prefs.externalThemeMutationID = UUID()
        }
        assertObserved("keep-awake stamp revision") {
            prefs.keepScreenAwakeRevision += 1
        }
        assertObserved("keep-awake stamp mutation") {
            prefs.keepScreenAwakeMutationID = UUID()
        }
        assertObserved("focus-minutes stamp revision") {
            prefs.preferredFocusMinutesRevision += 1
        }
        assertObserved("focus-minutes stamp mutation") {
            prefs.preferredFocusMinutesMutationID = UUID()
        }
        assertObserved("usage-purpose stamp revision") {
            prefs.usagePurposeRevision += 1
        }
        assertObserved("usage-purpose stamp mutation") {
            prefs.usagePurposeMutationID = UUID()
        }
        assertObserved("onboarding lifecycle") {
            prefs.hasCompletedOnboarding = true
        }
        assertObserved("bedrock lifecycle") {
            prefs.hasEverImportedBedrock = true
        }
        assertObserved("subject-seed lifecycle") {
            prefs.hasCompletedInitialSubjectSeed = true
        }
    }

    func testSyncNotificationEntityLiteralsMatchPersistentIdentifiers() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let session = makeSession(id: UUID(), epochID: nil)
        let marker = ActivityResetMarker(
            epochID: UUID(),
            sequence: 1,
            resetAt: .now,
            writerDeviceID: "test"
        )
        context.insert(session)
        context.insert(marker)
        try context.save()

        XCTAssertTrue(SyncMaintenanceNotificationPolicy
            .aggregateSourceEntityNames.contains(
                session.persistentModelID.entityName
            ))
        XCTAssertTrue(SyncMaintenanceNotificationPolicy
            .aggregateSourceEntityNames.contains(
                marker.persistentModelID.entityName
            ))
    }

    func testStoreChangeClassifierFiltersStoreURLAndWriterOrigin() {
        let sourceURL = URL(fileURLWithPath: "/tmp/account/source.sqlite")
        let projectionURL = URL(fileURLWithPath: "/tmp/account/projection.sqlite")
        let remoteSource = SyncStoreChangeSignal(
            source: .persistentStoreRemoteChange,
            persistentStoreURL: sourceURL
        )
        XCTAssertEqual(
            SyncStoreChangeClassifier.classify(
                remoteSource,
                persistenceMode: .cloudKit,
                maintenanceWorkerIsInFlight: false,
                expectedCloudSourceStoreURL: sourceURL
            ),
            .invalidateSessionDependents
        )
        XCTAssertEqual(
            SyncStoreChangeClassifier.classify(
                SyncStoreChangeSignal(
                    source: .persistentStoreRemoteChange,
                    persistentStoreURL: projectionURL
                ),
                persistenceMode: .cloudKit,
                maintenanceWorkerIsInFlight: false,
                expectedCloudSourceStoreURL: sourceURL
            ),
            .ignoreIrrelevant
        )
        XCTAssertEqual(
            SyncStoreChangeClassifier.classify(
                SyncStoreChangeSignal(source: .persistentStoreRemoteChange),
                persistenceMode: .cloudKit,
                maintenanceWorkerIsInFlight: false,
                expectedCloudSourceStoreURL: sourceURL
            ),
            .ignoreIrrelevant
        )

        let mainSave = SyncStoreChangeSignal(
            source: .modelContextDidSave,
            contextOrigin: .mainContext,
            changedEntityNames: ["StudySession"]
        )
        XCTAssertEqual(
            SyncStoreChangeClassifier.classify(
                mainSave,
                persistenceMode: .cloudKit,
                maintenanceWorkerIsInFlight: true
            ),
            .invalidateSessionDependents,
            "a user save concurrent with maintenance must bump the generation"
        )
        XCTAssertEqual(
            SyncStoreChangeClassifier.classify(
                SyncStoreChangeSignal(
                    source: .modelContextDidSave,
                    contextOrigin: .otherContext,
                    changedEntityNames: ["StudySession"]
                ),
                persistenceMode: .cloudKit,
                maintenanceWorkerIsInFlight: false
            ),
            .ignoreMaintenanceWriter,
            "a delayed iOS 17 worker didSave must not create a self-loop"
        )
        XCTAssertEqual(
            SyncStoreChangeClassifier.classify(
                SyncStoreChangeSignal(
                    source: .modelContextDidSave,
                    contextOrigin: .otherContext,
                    author: SyncMaintenanceNotificationPolicy.maintenanceAuthor,
                    changedEntityNames: ["StudySession"]
                ),
                persistenceMode: .cloudKit,
                maintenanceWorkerIsInFlight: false
            ),
            .ignoreMaintenanceWriter
        )
        XCTAssertEqual(
            SyncStoreChangeClassifier.classify(
                remoteSource,
                persistenceMode: .localOnly,
                maintenanceWorkerIsInFlight: false,
                expectedCloudSourceStoreURL: sourceURL
            ),
            .ignoreIrrelevant
        )
    }

    func testRemoteSourceChangeDefersDuringWorkerWithoutLosingReason() {
        XCTAssertEqual(
            SyncStoreChangeSchedulingPolicy.decision(
                classification: .invalidateSessionDependents,
                source: .persistentStoreRemoteChange,
                maintenanceWorkerIsInFlight: true
            ),
            .deferRemoteUntilWorkerQuiesces
        )
        XCTAssertEqual(
            SyncStoreChangeSchedulingPolicy.decision(
                classification: .invalidateSessionDependents,
                source: .modelContextDidSave,
                maintenanceWorkerIsInFlight: true
            ),
            .enqueueSessionDependents
        )
        XCTAssertEqual(
            SyncStoreChangeSchedulingPolicy.decision(
                classification: .invalidateSessionDependents,
                source: .persistentStoreRemoteChange,
                maintenanceWorkerIsInFlight: false
            ),
            .enqueueSessionDependents
        )
        XCTAssertFalse(SyncDeferredSourceInvalidationPolicy.shouldConsume(
            isDeferred: true,
            maintenanceWorkerIsInFlight: true
        ))
        XCTAssertTrue(SyncDeferredSourceInvalidationPolicy.shouldConsume(
            isDeferred: true,
            maintenanceWorkerIsInFlight: false
        ))
    }

    func testDeferredRemoteImportPreemptsUnrelatedDenseRetryAtNextBoundary() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var checkpoint = SyncMaintenanceCheckpoint()
        checkpoint.enqueue(.aggregates)
        let aggregateRequest = try! XCTUnwrap(
            checkpoint.nextRequest(now: now)
        )
        XCTAssertTrue(checkpoint.apply(.retry(
            request: aggregateRequest,
            cursor: SyncMaintenanceCursor(
                observedWinningEpochID: UUID(),
                phase: 4,
                offset: 256
            ),
            audit: SyncMaintenanceFetchAudit(),
            category: "dense-retry"
        ), now: now))
        checkpoint.enqueue(.verificationSweep)
        XCTAssertNil(checkpoint.nextRequest(
            now: now.addingTimeInterval(0.5)
        ))

        XCTAssertTrue(SyncDeferredSourceInvalidationPolicy.shouldConsume(
            isDeferred: true,
            maintenanceWorkerIsInFlight: false
        ))
        checkpoint.enqueue(.sessions)
        checkpoint.enqueue(.verificationSweep)
        XCTAssertEqual(
            checkpoint.nextRequest(now: now.addingTimeInterval(0.5))?.kind,
            .sessions,
            "a genuine source import must not wait behind an unrelated retry"
        )
    }

    func testStoreChangeDebouncerPreservesTrailingInvalidation() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var debouncer = SyncStoreChangeDebouncer()
        XCTAssertEqual(
            debouncer.decision(
                for: .invalidateSessionDependents,
                now: start,
                interval: 1
            ),
            .acceptNow
        )
        XCTAssertEqual(
            debouncer.decision(
                for: .invalidateSessionDependents,
                now: start.addingTimeInterval(0.4),
                interval: 1
            ),
            .scheduleTrailing(start.addingTimeInterval(1))
        )
        XCTAssertFalse(debouncer.consumeTrailing(
            now: start.addingTimeInterval(0.99)
        ))
        XCTAssertTrue(debouncer.consumeTrailing(
            now: start.addingTimeInterval(1)
        ))
        XCTAssertNil(debouncer.trailingDeadline)
    }

    func testTrailingSourceChangeKeepsTrustRevokedUntilFreshSweepTicket() {
        var checkpoint = SyncMaintenanceCheckpoint()
        checkpoint.enqueue(.verificationSweep)
        let firstGeneration = try! XCTUnwrap(
            checkpoint.generation(for: .verificationSweep)
        )
        let staleTicket = AggregateProjectionVerificationTicket(
            verificationSweepGeneration: firstGeneration
        )
        let firstRequest = try! XCTUnwrap(checkpoint.nextRequest())
        XCTAssertTrue(checkpoint.apply(.completed(
            request: firstRequest,
            audit: SyncMaintenanceFetchAudit()
        )))
        XCTAssertTrue(staleTicket.isSatisfied(by: checkpoint))

        var presentation = AggregateProjectionPresentationContext.initial(
            for: .cloudKit
        )
        presentation.markVerified()

        // Root's trailing-edge contract durably bumps source work, revokes
        // presentation immediately, and discards the old ticket before it
        // coalesces the next expensive verification request.
        checkpoint.enqueue(.sessions)
        presentation.invalidate()
        var activeTicket: AggregateProjectionVerificationTicket? = nil
        XCTAssertTrue(presentation.isCloudVerificationPending)
        XCTAssertNil(activeTicket)
        XCTAssertFalse(staleTicket.isSatisfied(by: checkpoint))

        while let request = checkpoint.nextRequest() {
            XCTAssertTrue(checkpoint.apply(.completed(
                request: request,
                audit: SyncMaintenanceFetchAudit()
            )))
        }
        // The prior schema marker becomes clean again, so keeping `staleTicket`
        // would be unsafe. The discarded active ticket keeps UI pending.
        XCTAssertTrue(staleTicket.isSatisfied(by: checkpoint))
        XCTAssertTrue(presentation.isCloudVerificationPending)

        checkpoint.enqueue(.verificationSweep)
        let freshGeneration = try! XCTUnwrap(
            checkpoint.generation(for: .verificationSweep)
        )
        activeTicket = AggregateProjectionVerificationTicket(
            verificationSweepGeneration: freshGeneration
        )
        let freshRequest = try! XCTUnwrap(checkpoint.nextRequest())
        XCTAssertTrue(checkpoint.apply(.completed(
            request: freshRequest,
            audit: SyncMaintenanceFetchAudit()
        )))
        XCTAssertTrue(activeTicket?.isSatisfied(by: checkpoint) == true)
        presentation.markVerified()
        XCTAssertFalse(presentation.isCloudVerificationPending)
    }

    func testCloudPresentationStartsPendingAndNeverUsesLowerBoundCopy() {
        let pending = AggregateProjectionPresentationContext.initial(
            for: .cloudKit
        )
        XCTAssertTrue(pending.isCloudVerificationPending)
        XCTAssertFalse(pending.allowsAggregateSummaries)
        XCTAssertEqual(
            AggregateProjectionPresentationPolicy.homeMassValue(
                verifiedValue: "12 kg",
                context: pending
            ),
            "再集計中"
        )
        let values = [
            AggregateProjectionPresentationPolicy.homeMassUnit(
                verifiedUnit: "kg",
                hasLocalLowerBound: true,
                context: pending
            ),
            AggregateProjectionPresentationPolicy.homeCountSummary(
                count: 12,
                milestoneSuffix: "",
                hasLocalLowerBound: true,
                context: pending
            ),
            AggregateProjectionPresentationPolicy.overviewLifetimeValue(
                verifiedValue: "12 kg",
                isLocalLowerBound: true,
                context: pending
            )
        ]
        XCTAssertTrue(values.joined().contains("確認済み"))
        XCTAssertFalse(values.joined().contains("+"))
        XCTAssertFalse(values.joined().contains("以上"))

        let pendingOverview = AccumulationOverviewPageScope(
            totalSessionCount: 0,
            displayedSessionCount: 0,
            totalSessionCountIsCloudUnverified: true,
            totalAchievementCount: 0,
            displayedAchievementCount: 0
        )
        XCTAssertTrue(pendingOverview.emptyShelfMessage.contains("再集計中"))
        XCTAssertFalse(pendingOverview.emptyShelfMessage.contains("最初の一粒"))

        let local = AggregateProjectionPresentationContext.initial(
            for: .localOnly
        )
        XCTAssertTrue(local.isVerified)
        XCTAssertEqual(
            AggregateProjectionPresentationPolicy.homeMassUnit(
                verifiedUnit: "kg",
                hasLocalLowerBound: true,
                context: local
            ),
            "kg以上"
        )
    }

    func testMaintenanceLaunchResumeAndRecurringPolicyIsTabIndependent() {
        XCTAssertTrue(SyncMaintenanceLaunchPolicy
            .requiresInitialVerificationSweep(for: .cloudKit))
        XCTAssertFalse(SyncMaintenanceLaunchPolicy
            .requiresInitialVerificationSweep(for: .localOnly))
        XCTAssertEqual(
            SyncMaintenanceLaunchPolicy.foregroundIdleGrace,
            .seconds(60)
        )
        XCTAssertEqual(
            SyncMaintenanceLaunchPolicy.recurringVerificationInterval,
            .seconds(15 * 60)
        )
        for tab: AppTab in [.jar, .log, .settings] {
            XCTAssertTrue(SyncMaintenanceLaunchPolicy
                .permitsForegroundDrain(on: tab))
        }
        XCTAssertTrue(SyncMaintenanceLaunchPolicy
            .shouldScheduleRecurringVerification(
                for: .cloudKit,
                sceneIsActive: true
            ))
        XCTAssertFalse(SyncMaintenanceLaunchPolicy
            .shouldScheduleRecurringVerification(
                for: .cloudKit,
                sceneIsActive: false
            ))
        XCTAssertFalse(SyncMaintenanceLaunchPolicy
            .shouldScheduleRecurringVerification(
                for: .localOnly,
                sceneIsActive: true
            ))
        XCTAssertTrue(SyncMaintenanceLaunchPolicy
            .shouldResetForegroundGrace(after: .background))
        XCTAssertFalse(SyncMaintenanceLaunchPolicy
            .shouldResetForegroundGrace(after: .inactive))
        XCTAssertTrue(SyncMaintenanceLaunchPolicy
            .shouldRearmForegroundWork(after: .active))
        XCTAssertFalse(SyncMaintenanceLaunchPolicy
            .shouldRearmForegroundWork(after: .inactive))
    }

    func testVerificationTicketWaitsForFollowupsAndRejectsOldGeneration() {
        var checkpoint = SyncMaintenanceCheckpoint()
        checkpoint.enqueue(.verificationSweep)
        let generation = try! XCTUnwrap(
            checkpoint.generation(for: .verificationSweep)
        )
        let ticket = AggregateProjectionVerificationTicket(
            verificationSweepGeneration: generation
        )
        let request = try! XCTUnwrap(checkpoint.nextRequest())
        XCTAssertTrue(checkpoint.apply(.completed(
            request: request,
            audit: SyncMaintenanceFetchAudit(),
            followups: [.sessions]
        )))
        XCTAssertFalse(ticket.isSatisfied(by: checkpoint))

        while let next = checkpoint.nextRequest() {
            XCTAssertTrue(checkpoint.apply(.completed(
                request: next,
                audit: SyncMaintenanceFetchAudit()
            )))
        }
        XCTAssertTrue(ticket.isSatisfied(by: checkpoint))

        checkpoint.enqueue(.verificationSweep)
        XCTAssertFalse(
            ticket.isSatisfied(by: checkpoint),
            "a new import generation must supersede the old clean ticket"
        )
    }

    func testVerificationSweepWaitsBehindBackedOffMaintenanceCursor() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var checkpoint = SyncMaintenanceCheckpoint()
        checkpoint.enqueue(.aggregates)
        let aggregateRequest = try! XCTUnwrap(
            checkpoint.nextRequest(now: now)
        )
        let retryCursor = SyncMaintenanceCursor(
            observedWinningEpochID: UUID(),
            phase: 7,
            offset: 512
        )
        XCTAssertTrue(checkpoint.apply(.retry(
            request: aggregateRequest,
            cursor: retryCursor,
            audit: SyncMaintenanceFetchAudit(),
            category: "dense-test"
        ), now: now))
        checkpoint.enqueue(.verificationSweep)

        XCTAssertNil(
            checkpoint.nextRequest(now: now.addingTimeInterval(0.5)),
            "verification must not jump ahead of a backed-off non-verification kind"
        )
        let resumed = try! XCTUnwrap(
            checkpoint.nextRequest(now: now.addingTimeInterval(1))
        )
        XCTAssertEqual(resumed.kind, .aggregates)
        XCTAssertEqual(resumed.cursor, retryCursor)
        XCTAssertTrue(checkpoint.apply(.completed(
            request: resumed,
            audit: SyncMaintenanceFetchAudit()
        )))
        XCTAssertEqual(
            checkpoint.nextRequest(now: now.addingTimeInterval(1))?.kind,
            .verificationSweep
        )
    }

    func testProjectionCacheStampDoesNotReviveAcrossFalseTrueFalseTransition() {
        var presentation = AggregateProjectionPresentationContext.initial(
            for: .cloudKit
        )
        presentation.markVerified()
        let preImportStamp = try! XCTUnwrap(presentation.verifiedCacheStamp)
        XCTAssertTrue(presentation.acceptsVerifiedAggregateCache(preImportStamp))

        presentation.invalidate()
        XCTAssertTrue(presentation.isCloudVerificationPending)
        XCTAssertFalse(presentation.acceptsVerifiedAggregateCache(preImportStamp))

        presentation.markVerified()
        XCTAssertFalse(presentation.isCloudVerificationPending)
        XCTAssertFalse(
            presentation.acceptsVerifiedAggregateCache(preImportStamp),
            "pending becoming false must not revive a pre-import cache"
        )
        let reloadedStamp = try! XCTUnwrap(presentation.verifiedCacheStamp)
        XCTAssertTrue(presentation.acceptsVerifiedAggregateCache(reloadedStamp))
        XCTAssertNotEqual(preImportStamp, reloadedStamp)
    }

    func testProjectionCacheStampRotatesNamespaceAtEpochExhaustion() {
        var presentation = AggregateProjectionPresentationContext(
            usesCloudPersistence: true,
            isVerified: true,
            cacheNamespace: UUID(
                uuidString: "11111111-1111-1111-1111-111111111111"
            )!,
            verificationEpoch: .max
        )
        let exhaustedStamp = presentation.verifiedCacheStamp

        presentation.invalidate()
        presentation.markVerified()

        XCTAssertEqual(presentation.verificationEpoch, 0)
        XCTAssertNotEqual(presentation.verifiedCacheStamp, exhaustedStamp)
        XCTAssertFalse(presentation.acceptsVerifiedAggregateCache(
            exhaustedStamp
        ))
    }

    func testPostDropReceiptFrozenProjectionRequiresCurrentVerificationStamp() throws {
        var presentation = AggregateProjectionPresentationContext.initial(
            for: .cloudKit
        )
        presentation.markVerified()
        let stamp = try XCTUnwrap(presentation.verifiedCacheStamp)
        let receipt = PendingRewardReceipt(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            breakMinutes: 5,
            grams: 250,
            subjectName: "数学",
            colorHex: "FF0000",
            weeklyCompletionCount: 4,
            weeklyStudyGrams: 1_000,
            kind: .normal,
            totalPebbleCount: 20,
            totalStudyGrams: 5_000,
            projectionIsLowerBound: false,
            projectionCacheStamp: stamp
        )
        let decoded = try JSONDecoder().decode(
            PendingRewardReceipt.self,
            from: JSONEncoder().encode(receipt)
        )
        XCTAssertEqual(decoded.projectionCacheStamp, stamp)

        presentation.invalidate()
        presentation.markVerified()
        XCTAssertFalse(presentation.acceptsVerifiedAggregateCache(
            decoded.projectionCacheStamp
        ))
    }

    func testQueuedCelebrationSnapshotRequiresCurrentVerificationStamp() throws {
        var presentation = AggregateProjectionPresentationContext.initial(
            for: .cloudKit
        )
        presentation.markVerified()
        let stamp = try XCTUnwrap(presentation.verifiedCacheStamp)
        let celebration = PendingStratumCelebration(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            pebbleCount: 10,
            grams: 2_500,
            monthLabel: "2026年9月",
            level: 1,
            projectionCacheStamp: stamp
        )
        let decoded = try JSONDecoder().decode(
            PendingStratumCelebration.self,
            from: JSONEncoder().encode(celebration)
        )
        XCTAssertEqual(decoded.projectionCacheStamp, stamp)

        presentation.invalidate()
        presentation.markVerified()
        XCTAssertFalse(presentation.acceptsVerifiedAggregateCache(
            decoded.projectionCacheStamp
        ))
    }

    func testOverviewAndShareAggregatePagesNeedFreshPostVerificationLoad() {
        var presentation = AggregateProjectionPresentationContext.initial(
            for: .cloudKit
        )
        presentation.markVerified()
        let overviewPageStamp = presentation.verifiedCacheStamp
        let sharePageStamp = presentation.verifiedCacheStamp

        presentation.invalidate()
        XCTAssertFalse(presentation.acceptsVerifiedAggregateCache(
            overviewPageStamp
        ))
        XCTAssertFalse(presentation.acceptsVerifiedAggregateCache(
            sharePageStamp
        ))

        presentation.markVerified()
        XCTAssertFalse(presentation.acceptsVerifiedAggregateCache(
            overviewPageStamp
        ))
        XCTAssertFalse(presentation.acceptsVerifiedAggregateCache(
            sharePageStamp
        ))

        let freshlyReloadedOverview = presentation.verifiedCacheStamp
        let freshlyReloadedShare = presentation.verifiedCacheStamp
        XCTAssertTrue(presentation.acceptsVerifiedAggregateCache(
            freshlyReloadedOverview
        ))
        XCTAssertTrue(presentation.acceptsVerifiedAggregateCache(
            freshlyReloadedShare
        ))
    }

    func testAggregateProjectionFingerprintObservesEveryDecisionField() {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let aggregate = AggregatePebble(
            id: UUID(),
            createdAt: first,
            level: 1,
            pebbleCount: 10,
            childAggregateCount: 1,
            grams: 250,
            measuredPebbleCount: 9,
            manualPebbleCount: 1,
            goldPebbleCount: 2,
            prismPebbleCount: 1,
            colorMixJSON: "[]",
            subjectMixJSON: "[]",
            periodStart: first,
            periodEnd: first.addingTimeInterval(60),
            sessionIDs: [UUID()],
            childAggregateIDs: [UUID()],
            parentAggregateID: UUID(),
            dataEpochID: UUID(),
            projectionValidationVersion: 1
        )
        func fingerprint() -> String {
            AggregateProjectionChangeFingerprint.value(for: aggregate)
        }
        func assertObserved(
            _ label: String,
            mutation: () -> Void
        ) {
            let before = fingerprint()
            mutation()
            XCTAssertNotEqual(before, fingerprint(), label)
        }

        assertObserved("id") { aggregate.id = UUID() }
        assertObserved("epoch") { aggregate.dataEpochID = UUID() }
        assertObserved("createdAt") { aggregate.createdAt.addTimeInterval(1) }
        assertObserved("level") { aggregate.level += 1 }
        assertObserved("pebbleCount") { aggregate.pebbleCount += 1 }
        assertObserved("child count") { aggregate.childAggregateCount += 1 }
        assertObserved("grams") { aggregate.grams += 1 }
        assertObserved("measured") { aggregate.measuredPebbleCount += 1 }
        assertObserved("manual") { aggregate.manualPebbleCount += 1 }
        assertObserved("gold") { aggregate.goldPebbleCount += 1 }
        assertObserved("prism") { aggregate.prismPebbleCount += 1 }
        assertObserved("color mix") { aggregate.colorMixJSON = "[1]" }
        assertObserved("subject mix") { aggregate.subjectMixJSON = "[1]" }
        assertObserved("period start") { aggregate.periodStart.addTimeInterval(1) }
        assertObserved("period end") { aggregate.periodEnd.addTimeInterval(1) }
        assertObserved("sessions") { aggregate.sessionIDsJSON = "[]" }
        assertObserved("children") { aggregate.childAggregateIDsJSON = "[]" }
        assertObserved("parent") { aggregate.parentAggregateID = UUID() }
        assertObserved("validation") { aggregate.projectionValidationVersion += 1 }
    }

    private func makeSession(
        id: UUID,
        epochID: UUID?,
        endAt: Date = .now,
        kind: PebbleKind = .normal
    ) -> StudySession {
        StudySession(
            id: id,
            startAt: endAt.addingTimeInterval(-1_500),
            endAt: endAt,
            seconds: 1_500,
            source: .timer,
            pebbleKind: kind,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: endAt),
            dataEpochID: epochID
        )
    }

    private func uuid(_ value: String) -> UUID {
        try! XCTUnwrap(UUID(uuidString: value))
    }
}
