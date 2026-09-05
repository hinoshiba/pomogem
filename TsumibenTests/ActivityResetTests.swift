import SwiftData
import XCTest
@testable import Tsumiben

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
