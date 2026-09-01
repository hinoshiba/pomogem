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

    func testPreparationCanonicalizesSingletonsWithoutFoldingStudyHistory() throws {
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
        XCTAssertEqual(result.canonicalGacha.id, BoundedLaunchPreparation.canonicalGachaID)
        XCTAssertEqual(result.canonicalGacha.dataEpochID, epochID)
        XCTAssertEqual(result.canonicalGacha.sinceLastGold, 17)
        XCTAssertEqual(result.canonicalGacha.rewardCreditGrams, 350)
        XCTAssertEqual(result.canonicalGacha.rewardCreditRemainderGrams, 100)
        XCTAssertTrue(result.hasSyncedUsageEvidence)
        XCTAssertEqual(result.fetchAudit.maximumRowsReturnedByAnyFetch, 1)
        XCTAssertEqual(result.deferredMaintenanceReasons, [
            .prefsSingletonCanonicalized,
            .gachaSingletonCanonicalized
        ])

        XCTAssertEqual(unknownPrefs.id, uuid("30000000-0000-0000-0000-000000000002"))
        XCTAssertEqual(unknownPrefs.activityEpochID, unknownEpochID)
        XCTAssertEqual(unknownGacha.id, uuid("40000000-0000-0000-0000-000000000002"))
        XCTAssertEqual(unknownGacha.sinceLastGold, 99)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Prefs>()).count, 2)
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
        XCTAssertLessThanOrEqual(materialized.fetchAudit.maximumRowsReturnedByAnyFetch, 1)

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

    func testEveryColdStartQueryContractIsOneRow() {
        XCTAssertEqual(BoundedLaunchPreparation.QueryContract.latestResetMarkerLimit, 1)
        XCTAssertEqual(BoundedLaunchPreparation.QueryContract.singletonLimit, 1)
        XCTAssertEqual(BoundedLaunchPreparation.QueryContract.onboardingEvidenceLimit, 1)
        XCTAssertEqual(BoundedLaunchPreparation.QueryContract.pendingCompletionLimit, 1)
        XCTAssertEqual(BoundedLaunchPreparation.QueryContract.matchingResetMarkerLimit, 1)
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
