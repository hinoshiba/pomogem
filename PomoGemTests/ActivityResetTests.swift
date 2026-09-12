import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class ActivityResetTests: XCTestCase {
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
            "ActivityResetTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func testObservedLamportWinnerDoesNotFlipWithWallClock() {
        let now = Date(timeIntervalSince1970: 1_800_000_120)
        let observedWinner = ActivityResetSnapshot(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            epochID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            sequence: 9,
            resetAt: Date(timeIntervalSince1970: 1_800_000_000),
            writerDeviceID: "iphone"
        )
        let unawareOffline = ActivityResetSnapshot(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            epochID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            sequence: 0,
            resetAt: observedWinner.resetAt.addingTimeInterval(60),
            writerDeviceID: "offline-mac"
        )

        XCTAssertEqual(
            ActivityResetPolicy.currentMarker(
                from: [unawareOffline, observedWinner],
                now: now
            ),
            observedWinner
        )
        XCTAssertEqual(
            ActivityResetPolicy.currentMarker(
                from: [observedWinner, unawareOffline],
                now: now.addingTimeInterval(60 * 60 * 24 * 365 * 100)
            ),
            observedWinner
        )
        XCTAssertEqual(
            ActivityResetPolicy.nextSequence(from: [unawareOffline, observedWinner]),
            10
        )
    }

    func testConcurrentResetTieConvergesIndependentOfDeliveryOrder() {
        let instant = Date(timeIntervalSince1970: 1_800_050_000)
        let alpha = ActivityResetSnapshot(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000011")!,
            epochID: UUID(uuidString: "20000000-0000-0000-0000-000000000011")!,
            sequence: 4,
            resetAt: instant,
            writerDeviceID: "device-a"
        )
        let beta = ActivityResetSnapshot(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000012")!,
            epochID: UUID(uuidString: "20000000-0000-0000-0000-000000000012")!,
            sequence: 4,
            resetAt: instant,
            writerDeviceID: "device-b"
        )

        XCTAssertEqual(
            ActivityResetPolicy.currentMarker(from: [alpha, beta], now: instant),
            beta
        )
        XCTAssertEqual(
            ActivityResetPolicy.currentMarker(from: [beta, alpha], now: instant),
            beta
        )
    }

    func testCloudResetRejectsFreshReplicaBeforeMutationAndPreservesDelayedHistory() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let originalResetDate = Date(timeIntervalSince1970: 1_700_000_000)
        let localResetDate = originalResetDate.addingTimeInterval(86_400)
        let remoteEpoch = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let localEpoch = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let originalSessionID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let preferences = Prefs(manualDayKey: "2023-11-15", manualUsedToday: 2)
        context.insert(preferences)
        try context.save()

        // A reinstall can have preferences before its server reset history
        // arrives. The production entry point must reject the request before
        // accepting a sequence-0 marker or resetting existing local values.
        XCTAssertFalse(ActivityResetAdmissionPolicy.permitsUserReset(in: .cloudKit))
        XCTAssertThrowsError(try ActivityResetStore.beginUserInitiatedReset(
            context: context,
            persistenceMode: .cloudKit,
            deviceID: "reinstalled-device",
            now: localResetDate,
            epochID: localEpoch
        )) { error in
            XCTAssertEqual(error as? ActivityResetStoreError, .cloudResetUnavailable)
        }
        XCTAssertFalse(context.hasChanges)
        XCTAssertTrue(try ActivityResetStore.snapshots(context: context).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<StudySession>()).isEmpty)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Prefs>()), 1)
        XCTAssertEqual(preferences.manualDayKey, "2023-11-15")
        XCTAssertEqual(preferences.manualUsedToday, 2)

        // These rows already existed on the server before the rejected action.
        // Their delayed import must remain usable, with no falsely accepted
        // new generation whose completions could then be compacted away.
        context.insert(ActivityResetMarker(
            epochID: remoteEpoch,
            sequence: 9,
            resetAt: originalResetDate,
            writerDeviceID: "previous-installation"
        ))
        let originalSessionStart = originalResetDate.addingTimeInterval(60)
        context.insert(StudySession(
            id: originalSessionID,
            startAt: originalSessionStart,
            endAt: originalSessionStart.addingTimeInterval(1_500),
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: originalSessionStart),
            dataEpochID: remoteEpoch
        ))
        try context.save()

        let hydratedMarkers = try ActivityResetStore.snapshots(context: context)
        let visibleIDs = Set(try context.fetch(FetchDescriptor<StudySession>())
            .filter { ActivityResetPolicy.isCurrent($0.dataEpochID, markers: hydratedMarkers) }
            .map(\.id))
        XCTAssertEqual(visibleIDs, [originalSessionID])
        try SeedData.bootstrap(context: context)
        let retainedIDs = Set(try context.fetch(FetchDescriptor<StudySession>()).map(\.id))
        XCTAssertEqual(retainedIDs, [originalSessionID])
        XCTAssertEqual(try ActivityResetStore.latestEpochID(context: context), remoteEpoch)
    }

    func testCloudResetAlsoRejectsAnAlreadyHydratedReplicaWithoutMutation() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let existing = try ActivityResetStore.beginReset(context: context, deviceID: "old-device")
        try context.save()
        let before = try ActivityResetStore.snapshots(context: context)

        XCTAssertThrowsError(try ActivityResetStore.beginUserInitiatedReset(
            context: context,
            persistenceMode: .cloudKit,
            deviceID: "current-device"
        )) { error in
            XCTAssertEqual(error as? ActivityResetStoreError, .cloudResetUnavailable)
        }

        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try ActivityResetStore.snapshots(context: context), before)
        XCTAssertEqual(try ActivityResetStore.latestEpochID(context: context), existing.epochID)
    }

    func testLocalOnlyUserResetRetainsExistingEpochOrdering() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let original = try ActivityResetStore.beginReset(context: context, deviceID: "local-device")
        try context.save()
        let originalEpoch = original.epochID
        let originalSequence = original.sequence

        XCTAssertTrue(ActivityResetAdmissionPolicy.permitsUserReset(in: .localOnly))
        let accepted = try ActivityResetStore.beginUserInitiatedReset(
            context: context,
            persistenceMode: .localOnly,
            deviceID: "local-device"
        )
        try context.save()

        let markers = try ActivityResetStore.snapshots(context: context)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(accepted.sequence, originalSequence + 1)
        XCTAssertEqual(try ActivityResetStore.latestEpochID(context: context), accepted.epochID)
        XCTAssertEqual(ActivityResetPolicy.state(of: originalEpoch, markers: markers), .stale)
        XCTAssertEqual(ActivityResetPolicy.state(of: accepted.epochID, markers: markers), .current)
    }

    func testFutureWallClockCannotOverrideHigherLamportSequence() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let valid = ActivityResetSnapshot(
            id: UUID(),
            epochID: UUID(),
            sequence: 7,
            resetAt: now.addingTimeInterval(-60),
            writerDeviceID: "valid-device"
        )
        let farFuture = ActivityResetSnapshot(
            id: UUID(),
            epochID: UUID(),
            sequence: 6,
            resetAt: now.addingTimeInterval(60 * 60 * 24 * 365 * 100),
            writerDeviceID: "bad-clock"
        )
        let markers = [farFuture, valid]

        XCTAssertEqual(
            ActivityResetPolicy.currentMarker(from: markers, now: now),
            valid
        )
        XCTAssertEqual(
            ActivityResetPolicy.state(of: valid.epochID, markers: markers, now: now),
            .current
        )
        XCTAssertEqual(
            ActivityResetPolicy.state(
                of: farFuture.epochID,
                markers: markers,
                now: now
            ),
                .stale
        )
        XCTAssertEqual(
            ActivityResetPolicy.nextSequence(from: markers, now: now),
            8,
            "wall-clock metadata must not alter the Lamport sequence"
        )
    }

    func testUnsupportedSequenceIsQuarantinedInsteadOfPinningResetOrder() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let corrupt = ActivityResetSnapshot(
            id: UUID(),
            epochID: UUID(),
            sequence: ActivityResetPolicy.maximumSupportedSequence + 1,
            resetAt: now,
            writerDeviceID: "corrupt"
        )

        XCTAssertNil(ActivityResetPolicy.currentMarker(from: [corrupt], now: now))
        XCTAssertEqual(
            ActivityResetPolicy.state(
                of: corrupt.epochID,
                markers: [corrupt],
                now: now
            ),
            .awaitingMarker
        )
        XCTAssertEqual(
            ActivityResetPolicy.state(of: nil, markers: [corrupt], now: now),
            .current
        )
    }

    func testUnknownEpochWaitsForOutOfOrderMarkerThenBecomesCurrent() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)
        let first = try ActivityResetStore.beginReset(
            context: context,
            deviceID: "iphone",
            now: Date.now.addingTimeInterval(-3_600)
        )
        try context.save()
        try SeedData.bootstrap(context: context)

        let futureEpoch = UUID()
        let futureSession = StudySession(
            startAt: first.resetAt.addingTimeInterval(60),
            endAt: first.resetAt.addingTimeInterval(1_560),
            seconds: 1_500,
            source: .timer,
            grams: 250,
            deviceDayKey: "2027-01-01",
            dataEpochID: futureEpoch
        )
        context.insert(futureSession)
        try context.save()
        try SeedData.bootstrap(context: context)

        let firstSnapshots = try ActivityResetStore.snapshots(context: context)
        XCTAssertEqual(
            ActivityResetPolicy.state(
                of: futureSession.dataEpochID,
                markers: firstSnapshots
            ),
            .awaitingMarker
        )
        XCTAssertFalse(ActivityResetPolicy.isCurrent(
            futureSession.dataEpochID,
            markers: firstSnapshots
        ))
        XCTAssertTrue(try context.fetch(FetchDescriptor<StudySession>())
            .contains { $0 === futureSession })

        context.insert(ActivityResetMarker(
            epochID: futureEpoch,
            sequence: 0,
            resetAt: first.resetAt.addingTimeInterval(120),
            writerDeviceID: "offline-mac"
        ))
        try context.save()
        try SeedData.bootstrap(context: context)

        let finalSnapshots = try ActivityResetStore.snapshots(context: context)
        XCTAssertTrue(ActivityResetPolicy.isCurrent(
            futureSession.dataEpochID,
            markers: finalSnapshots
        ))
        XCTAssertTrue(try context.fetch(FetchDescriptor<StudySession>())
            .contains { $0 === futureSession })
    }

    func testResetRejectsLateLegacyRowsAndDoesNotMergeOldDuplicate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        try SeedData.bootstrap(context: context)

        let logicalID = UUID()
        let start = Date.now.addingTimeInterval(-10_000)
        let legacy = StudySession(
            id: logicalID,
            startAt: start,
            endAt: start.addingTimeInterval(1_500),
            seconds: 1_500,
            source: .timer,
            pebbleKind: .prism,
            grams: 999,
            deviceDayKey: "2027-01-02"
        )
        context.insert(legacy)
        context.insert(AchievementStone(kind: .examPass))
        context.insert(Bedrock(hours: 40))
        context.insert(AggregatePebble(
            level: 1,
            pebbleCount: 1,
            grams: 999,
            colorMixJSON: "[]",
            periodStart: start,
            periodEnd: start.addingTimeInterval(1_500),
            sessionIDs: [logicalID]
        ))
        context.insert(Stratum(
            pebbleCount: 1,
            heightPt: 10,
            colorMixJSON: "[]",
            monthLabel: "2027年1月",
            grams: 999,
            sessionIDs: [logicalID]
        ))
        let preResetGacha = try XCTUnwrap(
            context.fetch(FetchDescriptor<GachaState>()).first
        )
        preResetGacha.sinceLastGold = 99
        try context.save()

        let marker = try ActivityResetStore.beginReset(
            context: context,
            deviceID: "iphone",
            now: start.addingTimeInterval(2_000)
        )
        try context.save()
        try SeedData.bootstrap(context: context)

        XCTAssertTrue(try context.fetch(FetchDescriptor<StudySession>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<AchievementStone>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<AggregatePebble>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Stratum>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Bedrock>()).isEmpty)

        // A reset-unaware offline device uploads the exact old logical UUID
        // after deletion, while the current device records a fresh generation.
        context.insert(StudySession(
            id: logicalID,
            startAt: start,
            endAt: start.addingTimeInterval(1_500),
            seconds: 1_500,
            source: .timer,
            pebbleKind: .prism,
            grams: 999,
            deviceDayKey: "2027-01-02"
        ))
        context.insert(StudySession(
            id: logicalID,
            startAt: marker.resetAt,
            endAt: marker.resetAt.addingTimeInterval(1_500),
            seconds: 1_500,
            source: .timer,
            pebbleKind: .normal,
            grams: 250,
            deviceDayKey: "2027-01-02",
            dataEpochID: marker.epochID
        ))
        context.insert(GachaState(sinceLastGold: 999))
        context.insert(Prefs(
            manualDayKey: FairnessPolicy.deviceDayKey(for: .now),
            manualUsedToday: 2
        ))

        var staleEngine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        let staleTimerID = UUID()
        try staleEngine.startFocus(
            isPro: false,
            now: start,
            sessionID: staleTimerID
        )
        let staleEnvelope = FocusRecoveryEnvelope(
            engine: staleEngine,
            subject: FocusSubjectSnapshot(
                id: UUID(),
                name: "旧データ",
                colorHex: "#888888"
            ),
            clockAnchor: nil,
            pendingCompletion: nil,
            savedAt: start
        )
        context.insert(try SyncedFocusTimer(
            sessionID: staleTimerID,
            status: .running,
            payload: FocusCloudPayload(envelope: staleEnvelope),
            updatedAt: start,
            writerDeviceID: "offline-device"
        ))
        context.insert(FocusTimerDeviceClaim(
            sessionID: staleTimerID,
            deviceID: "offline-device",
            sequence: 0,
            claimedAt: start
        ))
        try context.save()
        try SeedData.bootstrap(context: context)

        let sessions = try context.fetch(FetchDescriptor<StudySession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.dataEpochID, marker.epochID)
        XCTAssertEqual(sessions.first?.grams, 250)
        XCTAssertEqual(sessions.first?.pebbleKind, .normal)
        let currentWriter = try XCTUnwrap(
            PrefsSyncPolicy.fetchOwnedWriterRows(
                from: context,
                currentEpochID: marker.epochID
            ).first
        )
        XCTAssertEqual(currentWriter.activityEpochID, marker.epochID)
        XCTAssertEqual(currentWriter.manualUsedToday, 0)
        let resolvedPrefs = try PrefsSyncPolicy.resolvedState(
            in: PrefsSyncPolicy.fetchBounded(from: context),
            currentEpochID: marker.epochID
        )
        XCTAssertEqual(resolvedPrefs.manualUsedToday, 0)
        let gacha = try XCTUnwrap(context.fetch(FetchDescriptor<GachaState>()).first)
        XCTAssertEqual(gacha.dataEpochID, marker.epochID)
        XCTAssertEqual(gacha.sinceLastGold, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SyncedFocusTimer>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<FocusTimerDeviceClaim>()).isEmpty)
        XCTAssertNil(try FocusCloudSyncStore.canonicalActive(context: context))
    }
}
