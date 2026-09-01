import SwiftData
import XCTest
@testable import Tsumiben

final class FocusCloudSyncTests: XCTestCase {
    func testCompletionPersistenceResultOnlyRetiresRecoveryAfterMaterialization() {
        XCTAssertTrue(FocusCompletionPersistenceResult.inserted(.normal).mayRetireRecovery)
        XCTAssertTrue(FocusCompletionPersistenceResult.alreadyMaterialized.mayRetireRecovery)
        XCTAssertFalse(FocusCompletionPersistenceResult.rejectedOwnership.mayRetireRecovery)
    }

    private let sessionA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let sessionB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    private let recordA = UUID(uuidString: "10000000-0000-0000-0000-0000000000A1")!
    private let recordB = UUID(uuidString: "10000000-0000-0000-0000-0000000000B2")!

    func testPortablePayloadDropsForeignUptimeAndReanchorsOnAdoption() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: sessionA)
        let event = try XCTUnwrap(engine.advance(
            at: start.addingTimeInterval(1_500),
            observedUptime: 91_500
        ))
        guard case let .focusCompleted(completion) = event else {
            return XCTFail("Expected completion")
        }
        let source = FocusRecoveryEnvelope(
            engine: engine,
            subject: subject,
            clockAnchor: ClockAnchor(wallDate: start, systemUptime: 90_000),
            pendingCompletion: completion,
            savedAt: start.addingTimeInterval(1_500)
        )

        let payload = try FocusCloudPayload(envelope: source)
        XCTAssertNil(payload.pendingCompletion?.observedUptime)

        let adoptedAt = start.addingTimeInterval(1_510)
        let adopted = payload.recoveryEnvelope(adoptedAt: adoptedAt)
        XCTAssertEqual(adopted.pendingCompletion?.sessionID, sessionA)
        XCTAssertNil(adopted.pendingCompletion?.observedUptime)
        XCTAssertNil(adopted.clockAnchor, "A completed payload does not need a clock anchor")
    }

    func testOldestConcurrentActiveTimerWinsDeterministically() {
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let later = snapshot(
            recordID: recordB,
            sessionID: sessionB,
            status: .running,
            startedAt: start.addingTimeInterval(30),
            updatedAt: start.addingTimeInterval(30),
            writer: "iphone"
        )
        let existing = snapshot(
            recordID: recordA,
            sessionID: sessionA,
            status: .running,
            startedAt: start,
            updatedAt: start,
            writer: "mac"
        )

        XCTAssertEqual(
            FocusSyncPolicy.canonicalActive(from: [later, existing]),
            existing
        )
        XCTAssertEqual(
            FocusSyncPolicy.canonicalActive(from: [existing, later]),
            existing
        )
    }

    func testDelayedLosingTimerCannotReviveAfterWinnerCompletes() {
        let start = Date(timeIntervalSince1970: 1_800_150_000)
        let end = start.addingTimeInterval(1_500)
        let completedWinner = snapshot(
            recordID: recordA,
            sessionID: sessionA,
            status: .completed,
            startedAt: start,
            scheduledEndAt: end,
            updatedAt: end,
            terminalAt: end,
            revision: 3,
            writer: "iphone"
        )
        let delayedLoser = snapshot(
            recordID: recordB,
            sessionID: sessionB,
            status: .running,
            startedAt: start.addingTimeInterval(30),
            scheduledEndAt: end.addingTimeInterval(30),
            updatedAt: start.addingTimeInterval(30),
            writer: "offline-mac"
        )

        XCTAssertNil(FocusSyncPolicy.canonicalActive(
            from: [delayedLoser, completedWinner]
        ))

        let genuinelyNewTimer = snapshot(
            recordID: UUID(uuidString: "10000000-0000-0000-0000-0000000000C3")!,
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!,
            status: .running,
            startedAt: end.addingTimeInterval(1),
            scheduledEndAt: end.addingTimeInterval(1_501),
            updatedAt: end.addingTimeInterval(1),
            writer: "mac"
        )
        XCTAssertEqual(
            FocusSyncPolicy.canonicalActive(
                from: [genuinelyNewTimer, delayedLoser, completedWinner]
            ),
            genuinelyNewTimer
        )
    }

    func testCancellationBeforeScheduledEndBeatsRemoteCompletion() {
        let start = Date(timeIntervalSince1970: 1_800_200_000)
        let end = start.addingTimeInterval(1_500)
        let completion = snapshot(
            recordID: recordA,
            sessionID: sessionA,
            status: .completed,
            startedAt: start,
            scheduledEndAt: end,
            updatedAt: end,
            terminalAt: end,
            revision: 4,
            writer: "iphone"
        )
        let cancellation = snapshot(
            recordID: recordB,
            sessionID: sessionA,
            status: .cancelled,
            startedAt: start,
            scheduledEndAt: end,
            updatedAt: end.addingTimeInterval(-5),
            terminalAt: end.addingTimeInterval(-5),
            revision: 3,
            writer: "mac"
        )

        XCTAssertEqual(
            FocusSyncPolicy.resolveSameSession([completion, cancellation]),
            cancellation
        )
    }

    func testLateCancellationCannotEraseEarnedCompletion() {
        let start = Date(timeIntervalSince1970: 1_800_300_000)
        let end = start.addingTimeInterval(1_500)
        let completion = snapshot(
            recordID: recordA,
            sessionID: sessionA,
            status: .completionPending,
            startedAt: start,
            scheduledEndAt: end,
            updatedAt: end,
            terminalAt: nil,
            revision: 2,
            writer: "iphone"
        )
        let lateCancellation = snapshot(
            recordID: recordB,
            sessionID: sessionA,
            status: .cancelled,
            startedAt: start,
            scheduledEndAt: end,
            updatedAt: end.addingTimeInterval(10),
            terminalAt: end.addingTimeInterval(10),
            revision: 9,
            writer: "mac"
        )

        XCTAssertEqual(
            FocusSyncPolicy.resolveSameSession([lateCancellation, completion]),
            completion
        )
    }

    func testNewOwnershipEpochBeatsStaleOfflineCancellation() {
        let start = Date(timeIntervalSince1970: 1_800_350_000)
        let end = start.addingTimeInterval(1_500)
        let adoptedRunningState = snapshot(
            recordID: recordA,
            sessionID: sessionA,
            status: .running,
            startedAt: start,
            scheduledEndAt: end,
            updatedAt: start.addingTimeInterval(60),
            revision: 2,
            ownershipSequence: 1,
            writer: "mac"
        )
        let staleOfflineCancellation = snapshot(
            recordID: recordB,
            sessionID: sessionA,
            status: .cancelled,
            startedAt: start,
            scheduledEndAt: end,
            updatedAt: start.addingTimeInterval(70),
            terminalAt: start.addingTimeInterval(70),
            revision: 9,
            ownershipSequence: 0,
            writer: "iphone"
        )

        XCTAssertEqual(
            FocusSyncPolicy.resolveSameSession([
                staleOfflineCancellation,
                adoptedRunningState
            ]),
            adoptedRunningState
        )
    }

    func testRemoteTimerRequiresExplicitAdoptionAndOnlyOwnerMayNotifyOrCommit() {
        let start = Date(timeIntervalSince1970: 1_800_400_000)
        let timer = snapshot(
            recordID: recordA,
            sessionID: sessionA,
            status: .running,
            startedAt: start,
            scheduledEndAt: start.addingTimeInterval(1_500),
            updatedAt: start,
            writer: "iphone"
        )
        let iphoneClaim = claim(
            id: recordA,
            deviceID: "iphone",
            sequence: 0,
            at: start
        )

        XCTAssertEqual(
            FocusSyncPolicy.recoveryAction(
                canonical: timer,
                localSessionID: nil,
                currentDeviceID: "mac",
                claims: [iphoneClaim]
            ),
            .offerCloudRecovery
        )
        XCTAssertEqual(
            FocusSyncPolicy.notificationOwner(for: sessionA, claims: [iphoneClaim]),
            "iphone"
        )
        XCTAssertFalse(FocusSyncPolicy.mayMaterializeCompletion(
            sessionID: sessionA,
            existingSessionIDs: [],
            currentDeviceID: "mac",
            claims: [iphoneClaim]
        ))
        XCTAssertEqual(
            FocusSyncPolicy.completionMaterializationDecision(
                sessionID: sessionA,
                existingSessionIDs: [],
                currentDeviceID: "mac",
                claims: [iphoneClaim]
            ),
            .rejectedOwnership
        )

        let macClaim = claim(
            id: recordB,
            deviceID: "mac",
            sequence: 1,
            at: start.addingTimeInterval(60)
        )
        let adoptedClaims = [iphoneClaim, macClaim]
        XCTAssertEqual(
            FocusSyncPolicy.notificationOwner(for: sessionA, claims: adoptedClaims),
            "mac"
        )
        XCTAssertTrue(FocusSyncPolicy.mayMaterializeCompletion(
            sessionID: sessionA,
            existingSessionIDs: [],
            currentDeviceID: "mac",
            claims: adoptedClaims
        ))
        XCTAssertEqual(
            FocusSyncPolicy.completionMaterializationDecision(
                sessionID: sessionA,
                existingSessionIDs: [],
                currentDeviceID: "mac",
                claims: adoptedClaims
            ),
            .insert
        )
        XCTAssertFalse(FocusSyncPolicy.mayMaterializeCompletion(
            sessionID: sessionA,
            existingSessionIDs: [],
            currentDeviceID: "iphone",
            claims: adoptedClaims
        ))
        XCTAssertFalse(FocusSyncPolicy.mayMaterializeCompletion(
            sessionID: sessionA,
            existingSessionIDs: [sessionA],
            currentDeviceID: "mac",
            claims: adoptedClaims
        ))
        XCTAssertEqual(
            FocusSyncPolicy.completionMaterializationDecision(
                sessionID: sessionA,
                existingSessionIDs: [sessionA],
                currentDeviceID: "iphone",
                claims: adoptedClaims
            ),
            .alreadyMaterialized,
            "An existing synced StudySession is safe even after ownership moved"
        )
    }

    func testConcurrentOwnershipClaimsConvergeWithoutArrayOrderDependency() {
        let instant = Date(timeIntervalSince1970: 1_800_500_000)
        let alpha = claim(
            id: recordA,
            deviceID: "device-a",
            sequence: 4,
            at: instant
        )
        let beta = claim(
            id: recordB,
            deviceID: "device-b",
            sequence: 4,
            at: instant
        )

        XCTAssertEqual(
            FocusSyncPolicy.notificationOwner(for: sessionA, claims: [alpha, beta]),
            "device-b"
        )
        XCTAssertEqual(
            FocusSyncPolicy.notificationOwner(for: sessionA, claims: [beta, alpha]),
            "device-b"
        )
        XCTAssertEqual(
            FocusSyncPolicy.nextOwnershipSequence(for: sessionA, claims: [beta, alpha]),
            5
        )
    }

    @MainActor
    func testSwiftDataStoreRoundTripPreservesOneLogicalTimerAndClaim() throws {
        let schema = Schema([
            ActivityResetMarker.self,
            SyncedFocusTimer.self,
            FocusTimerDeviceClaim.self
        ])
        let configuration = ModelConfiguration(
            "FocusCloudSyncTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_800_600_000)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: sessionA)
        let envelope = FocusRecoveryEnvelope(
            engine: engine,
            subject: subject,
            clockAnchor: ClockAnchor(wallDate: start, systemUptime: 100),
            pendingCompletion: nil,
            savedAt: start
        )

        _ = try FocusCloudSyncStore.upsert(
            envelope: envelope,
            status: .running,
            context: context,
            deviceID: "iphone",
            claimIfUnowned: true,
            now: start
        )
        try context.save()

        let stored = try XCTUnwrap(FocusCloudSyncStore.canonicalActive(context: context))
        XCTAssertEqual(stored.sessionID, sessionA)
        XCTAssertEqual(try stored.decodedPayload().subject, subject)
        XCTAssertTrue(try FocusCloudSyncStore.isNotificationOwner(
            sessionID: sessionA,
            context: context,
            deviceID: "iphone"
        ))
    }

    @MainActor
    func testReconciliationTombstonePermanentlySuppressesDelayedLosingTimer() throws {
        let schema = Schema([
            ActivityResetMarker.self,
            SyncedFocusTimer.self,
            FocusTimerDeviceClaim.self
        ])
        let configuration = ModelConfiguration(
            "FocusCloudSyncLoserTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_800_650_000)
        let end = start.addingTimeInterval(1_500)

        var winningEngine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try winningEngine.startFocus(isPro: false, now: start, sessionID: sessionA)
        let winningEnvelope = FocusRecoveryEnvelope(
            engine: winningEngine,
            subject: subject,
            clockAnchor: nil,
            pendingCompletion: nil,
            savedAt: start
        )
        _ = try FocusCloudSyncStore.upsert(
            envelope: winningEnvelope,
            status: .running,
            context: context,
            deviceID: "iphone",
            claimIfUnowned: true,
            now: start
        )

        var losingEngine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        let losingStart = start.addingTimeInterval(30)
        try losingEngine.startFocus(isPro: false, now: losingStart, sessionID: sessionB)
        let losingEnvelope = FocusRecoveryEnvelope(
            engine: losingEngine,
            subject: subject,
            clockAnchor: nil,
            pendingCompletion: nil,
            savedAt: losingStart
        )
        _ = try FocusCloudSyncStore.upsert(
            envelope: losingEnvelope,
            status: .running,
            context: context,
            deviceID: "offline-mac",
            claimIfUnowned: true,
            now: losingStart
        )
        try FocusCloudSyncStore.markTerminal(
            sessionID: sessionA,
            status: .completed,
            context: context,
            deviceID: "iphone",
            at: end
        )
        try context.save()

        XCTAssertNil(try FocusCloudSyncStore.reconcileActiveTimers(
            context: context,
            deviceID: "reconciler",
            now: end.addingTimeInterval(1)
        ))
        try context.save()

        // Simulate the original offline running row arriving again after the
        // winner completed. Its huge revision must not beat the synthetic
        // higher-ownership cancellation tombstone.
        let stalePayload = try FocusCloudPayload(envelope: losingEnvelope)
        let staleRecord = try SyncedFocusTimer(
            sessionID: sessionB,
            status: .running,
            payload: stalePayload,
            updatedAt: losingStart.addingTimeInterval(60),
            revision: 999,
            ownershipSequence: 0,
            writerDeviceID: "offline-mac"
        )
        context.insert(staleRecord)
        try context.save()

        let allRecords = try context.fetch(FetchDescriptor<SyncedFocusTimer>())
        let losingWinner = try XCTUnwrap(FocusSyncPolicy.resolveSameSession(
            allRecords
                .filter { $0.sessionID == sessionB }
                .map(\.policySnapshot)
        ))
        XCTAssertEqual(losingWinner.status, .cancelled)
        XCTAssertNil(try FocusCloudSyncStore.canonicalActive(context: context))
    }

    @MainActor
    func testTerminalWriteFailsWhenNoSharedTimerHistoryExists() throws {
        let schema = Schema([
            ActivityResetMarker.self,
            SyncedFocusTimer.self,
            FocusTimerDeviceClaim.self
        ])
        let configuration = ModelConfiguration(
            "FocusCloudSyncMissingTimerTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])

        XCTAssertThrowsError(try FocusCloudSyncStore.markTerminal(
            sessionID: sessionA,
            status: .cancelled,
            context: container.mainContext,
            deviceID: "iphone"
        )) { error in
            XCTAssertEqual(error as? FocusCloudSyncError, .missingTimerRecord)
        }
    }

    func testDeviceIdentityIsStableButLocalToDefaultsDomain() throws {
        let suite = "FocusCloudSyncTests.device.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = FocusDeviceIdentity.current(defaults: defaults)
        XCTAssertEqual(FocusDeviceIdentity.current(defaults: defaults), first)
        XCTAssertFalse(first.isEmpty)
    }

    @MainActor
    func testOwnershipQueriesStayBoundedAndExactWithLifetimeNoise() throws {
        let schema = Schema([
            ActivityResetMarker.self,
            SyncedFocusTimer.self,
            FocusTimerDeviceClaim.self
        ])
        let configuration = ModelConfiguration(
            "FocusCloudSyncBoundedClaims",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_801_000_000)

        for index in 0..<400 {
            context.insert(FocusTimerDeviceClaim(
                sessionID: UUID(),
                deviceID: "old-\(index)",
                sequence: index,
                claimedAt: start.addingTimeInterval(TimeInterval(index))
            ))
        }
        for index in 0..<3 {
            context.insert(FocusTimerDeviceClaim(
                sessionID: sessionA,
                deviceID: "target-\(index)",
                sequence: index,
                claimedAt: start.addingTimeInterval(1_000 + TimeInterval(index))
            ))
        }
        try context.save()

        let exact = try FocusCloudSyncStore.claims(
            sessionID: sessionA,
            context: context
        )
        XCTAssertEqual(exact.count, 3)
        XCTAssertTrue(exact.allSatisfy { $0.sessionID == sessionA })
        XCTAssertLessThanOrEqual(
            try FocusCloudSyncStore.allClaims(context: context).count,
            FocusCloudSyncStore.QueryContract.recentOwnershipClaimLimit
        )
    }

    private var subject: FocusSubjectSnapshot {
        FocusSubjectSnapshot(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            name: "企画書",
            colorHex: "#3FA57C"
        )
    }

    private func snapshot(
        recordID: UUID,
        sessionID: UUID,
        status: SyncedFocusStatus,
        startedAt: Date,
        scheduledEndAt: Date? = nil,
        updatedAt: Date,
        terminalAt: Date? = nil,
        revision: Int = 1,
        ownershipSequence: Int = 0,
        writer: String
    ) -> FocusSyncRecordSnapshot {
        FocusSyncRecordSnapshot(
            recordID: recordID,
            sessionID: sessionID,
            status: status,
            startedAt: startedAt,
            scheduledEndAt: scheduledEndAt,
            updatedAt: updatedAt,
            terminalAt: terminalAt,
            revision: revision,
            ownershipSequence: ownershipSequence,
            writerDeviceID: writer
        )
    }

    private func claim(
        id: UUID,
        deviceID: String,
        sequence: Int,
        at date: Date
    ) -> FocusOwnershipClaimSnapshot {
        FocusOwnershipClaimSnapshot(
            id: id,
            sessionID: sessionA,
            deviceID: deviceID,
            sequence: sequence,
            claimedAt: date,
            releasedAt: nil
        )
    }
}
