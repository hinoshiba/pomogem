import SwiftData
import XCTest
@testable import PomoGem

final class FocusCloudSyncTests: XCTestCase {
    func testCompletionPersistenceResultOnlyRetiresRecoveryAfterMaterialization() {
        XCTAssertTrue(FocusCompletionPersistenceResult.inserted(.normal).mayRetireRecovery)
        XCTAssertTrue(FocusCompletionPersistenceResult.alreadyMaterialized.mayRetireRecovery)
        XCTAssertTrue(FocusCompletionPersistenceResult.cancelledBeforeCompletion.mayRetireRecovery)
        XCTAssertTrue(FocusCompletionPersistenceResult.discardedByReset.mayRetireRecovery)
        XCTAssertFalse(FocusCompletionPersistenceResult.awaitingMaterializedCompletion.mayRetireRecovery)
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

    func testPausedThenResumedCompletionRemainsAValidPendingPayload() throws {
        let start = Date(timeIntervalSince1970: 1_800_025_000)
        let pausedAt = start.addingTimeInterval(300)
        let resumedAt = pausedAt.addingTimeInterval(600)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: sessionA)
        try engine.pause(at: pausedAt)
        try engine.resume(at: resumedAt)

        let scheduledEnd = try XCTUnwrap(engine.endDate)
        let event = try XCTUnwrap(engine.advance(at: scheduledEnd))
        guard case let .focusCompleted(completion) = event else {
            return XCTFail("Expected completion")
        }

        XCTAssertEqual(completion.seconds, 1_500)
        XCTAssertEqual(
            completion.endedAt.timeIntervalSince(completion.startedAt),
            2_100,
            "The frozen wall span includes the pause while awarded seconds do not"
        )
        let record = try pendingTimerRecord(
            engine: engine,
            completion: completion,
            savedAt: scheduledEnd,
            writer: "device-a"
        )
        XCTAssertEqual(
            try record.decodedPayload().pendingCompletion,
            completion
        )
    }

    func testBackwardClockDuringPauseProducesValidDemotedPendingPayload() throws {
        let start = Date(timeIntervalSince1970: 1_800_030_000)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: sessionA)
        try engine.pause(at: start.addingTimeInterval(300))
        try engine.resume(at: start.addingTimeInterval(-3_600))

        let scheduledEnd = try XCTUnwrap(engine.endDate)
        let event = try XCTUnwrap(engine.advance(at: scheduledEnd))
        guard case let .focusCompleted(completion) = event else {
            return XCTFail("Expected completion")
        }
        XCTAssertEqual(completion.source, .timerDemoted)

        let record = try pendingTimerRecord(
            engine: engine,
            completion: completion,
            savedAt: scheduledEnd,
            writer: "device-a"
        )
        XCTAssertEqual(try record.decodedPayload().pendingCompletion, completion)
    }

    @MainActor
    func testUpsertAppendsChangedStateWhenWallClockMovesBackwardOrStandsStill() throws {
        let container = try focusContainer(named: "FocusCloudSyncBackwardClock")
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_800_050_000)
        let future = start.addingTimeInterval(3_600)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: sessionA)

        _ = try FocusCloudSyncStore.upsert(
            envelope: FocusRecoveryEnvelope(
                engine: engine,
                subject: subject,
                clockAnchor: nil,
                pendingCompletion: nil,
                savedAt: future
            ),
            status: .running,
            context: context,
            deviceID: "device-a",
            claimIfUnowned: true,
            now: future
        )
        try context.save()

        let event = try XCTUnwrap(engine.advance(
            at: start.addingTimeInterval(1_500)
        ))
        guard case let .focusCompleted(completion) = event else {
            return XCTFail("Expected completion")
        }
        let pending = try FocusCloudSyncStore.upsert(
            envelope: FocusRecoveryEnvelope(
                engine: engine,
                subject: subject,
                clockAnchor: nil,
                pendingCompletion: completion,
                savedAt: completion.endedAt
            ),
            status: .completionPending,
            context: context,
            deviceID: "device-a",
            claimIfUnowned: false,
            now: completion.endedAt
        )
        XCTAssertEqual(pending.status, .completionPending)
        XCTAssertEqual(pending.revision, 2)
        try FocusCloudSyncStore.markTerminal(
            sessionID: sessionA,
            status: .completed,
            context: context,
            deviceID: "device-a",
            at: completion.endedAt
        )
        try context.save()
        XCTAssertEqual(
            try FocusCloudSyncStore.completionGate(
                sessionID: sessionA,
                context: context
            ),
            .completedAwaitingSession
        )

        let sameInstantContainer = try focusContainer(
            named: "FocusCloudSyncSameInstantPause"
        )
        let sameInstantContext = sameInstantContainer.mainContext
        var pausingEngine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try pausingEngine.startFocus(
            isPro: false,
            now: start,
            sessionID: sessionB
        )
        let runningEnvelope = FocusRecoveryEnvelope(
            engine: pausingEngine,
            subject: subject,
            clockAnchor: nil,
            pendingCompletion: nil,
            savedAt: start
        )
        _ = try FocusCloudSyncStore.upsert(
            envelope: runningEnvelope,
            status: .running,
            context: sameInstantContext,
            deviceID: "device-b",
            claimIfUnowned: true,
            now: start
        )
        try pausingEngine.pause(at: start.addingTimeInterval(1))
        let paused = try FocusCloudSyncStore.upsert(
            envelope: FocusRecoveryEnvelope(
                engine: pausingEngine,
                subject: subject,
                clockAnchor: nil,
                pendingCompletion: nil,
                savedAt: start
            ),
            status: .paused,
            context: sameInstantContext,
            deviceID: "device-b",
            claimIfUnowned: false,
            now: start
        )
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(paused.revision, 2)
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

    func testIndependentTimerBecomesRecoverableAfterEarlierTimerCompletes() {
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

        XCTAssertEqual(
            FocusSyncPolicy.canonicalActive(from: [delayedLoser, completedWinner]),
            delayedLoser
        )

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
            delayedLoser
        )
    }

    func testMaterializedCompletionBeatsDelayedCancellation() {
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
            completion
        )
    }

    func testCancellationBeforeScheduledEndBeatsPendingCompletion() {
        let start = Date(timeIntervalSince1970: 1_800_250_000)
        let end = start.addingTimeInterval(1_500)
        let pending = snapshot(
            recordID: recordA,
            sessionID: sessionA,
            status: .completionPending,
            startedAt: start,
            scheduledEndAt: end,
            updatedAt: end,
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
            FocusSyncPolicy.resolveSameSession([pending, cancellation]),
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

    @MainActor
    func testPendingCompletionAdmissionIsIndependentOfCancellationDeliveryOrder() throws {
        let start = Date(timeIntervalSince1970: 1_800_325_000)
        let end = start.addingTimeInterval(1_500)

        for cancellationOffset in [-1.0, 1.0] {
            for cancellationArrivesFirst in [false, true] {
                let container = try focusContainer(
                    named: "FocusCloudSyncCancelOrder-\(cancellationOffset)-\(cancellationArrivesFirst)"
                )
                let context = container.mainContext
                var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
                try engine.startFocus(
                    isPro: false,
                    now: start,
                    sessionID: sessionA
                )
                _ = try FocusCloudSyncStore.upsert(
                    envelope: FocusRecoveryEnvelope(
                        engine: engine,
                        subject: subject,
                        clockAnchor: nil,
                        pendingCompletion: nil,
                        savedAt: start
                    ),
                    status: .running,
                    context: context,
                    deviceID: "device-a",
                    claimIfUnowned: true,
                    now: start
                )
                try insertTimerHistory(
                    count: 140, context: context, start: start, writer: "device-a"
                )
                let event = try XCTUnwrap(engine.advance(at: end))
                guard case let .focusCompleted(completion) = event else {
                    return XCTFail("Expected completion")
                }
                let pendingEnvelope = FocusRecoveryEnvelope(
                    engine: engine,
                    subject: subject,
                    clockAnchor: nil,
                    pendingCompletion: completion,
                    savedAt: end
                )
                let cancelledAt = end.addingTimeInterval(cancellationOffset)

                if cancellationArrivesFirst {
                    try FocusCloudSyncStore.markTerminal(
                        sessionID: sessionA,
                        status: .cancelled,
                        context: context,
                        deviceID: "device-a",
                        at: cancelledAt
                    )
                    try context.save()
                }

                if cancellationOffset < 0, cancellationArrivesFirst {
                    XCTAssertThrowsError(try FocusCloudSyncStore.upsert(
                        envelope: pendingEnvelope,
                        status: .completionPending,
                        context: context,
                        deviceID: "device-a",
                        claimIfUnowned: false,
                        now: end
                    )) { error in
                        XCTAssertEqual(
                            error as? FocusCloudSyncError,
                            .timerAlreadyTerminal
                        )
                    }
                } else {
                    _ = try FocusCloudSyncStore.upsert(
                        envelope: pendingEnvelope,
                        status: .completionPending,
                        context: context,
                        deviceID: "device-a",
                        claimIfUnowned: false,
                        now: end
                    )
                }

                if !cancellationArrivesFirst {
                    try FocusCloudSyncStore.markTerminal(
                        sessionID: sessionA,
                        status: .cancelled,
                        context: context,
                        deviceID: "device-a",
                        at: cancelledAt
                    )
                }
                try context.save()

                let gate = try FocusCloudSyncStore.completionGate(
                    sessionID: sessionA,
                    context: context
                )
                if cancellationOffset < 0 {
                    XCTAssertEqual(gate, .cancelledBeforeCompletion)
                } else {
                    XCTAssertEqual(gate, .open)
                    try FocusCloudSyncStore.markTerminal(
                        sessionID: sessionA,
                        status: .completed,
                        context: context,
                        deviceID: "device-a",
                        at: end
                    )
                    try context.save()
                    XCTAssertEqual(
                        try FocusCloudSyncStore.completionGate(
                            sessionID: sessionA,
                            context: context
                        ),
                        .completedAwaitingSession
                    )
                }
            }
        }
    }

    @MainActor
    func testForeignOwnerLateCancellationPreservesOldOwnerCompletionWitnessInBothOrders() throws {
        let start = Date(timeIntervalSince1970: 1_800_340_000)
        let end = start.addingTimeInterval(1_500)
        let cancelledAt = end.addingTimeInterval(1)

        for cancellationArrivesFirst in [false, true] {
            let container = try focusContainer(
                named: "FocusCloudSyncForeignCancelOrder-\(cancellationArrivesFirst)"
            )
            let context = container.mainContext
            var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
            try engine.startFocus(
                isPro: false,
                now: start,
                sessionID: sessionA
            )
            let running = try FocusCloudSyncStore.upsert(
                envelope: FocusRecoveryEnvelope(
                    engine: engine,
                    subject: subject,
                    clockAnchor: nil,
                    pendingCompletion: nil,
                    savedAt: start
                ),
                status: .running,
                context: context,
                deviceID: "device-a",
                claimIfUnowned: true,
                now: start
            )
            try context.save()
            // The only matching ancestor belongs to A's old revision. Newer
            // foreign history must not evict the lineage needed after handoff.
            try insertTimerHistory(
                count: 140, context: context,
                start: start.addingTimeInterval(1), writer: "history-only-device"
            )

            let event = try XCTUnwrap(engine.advance(at: end))
            guard case let .focusCompleted(completion) = event else {
                return XCTFail("Expected completion")
            }
            let pendingEnvelope = FocusRecoveryEnvelope(
                engine: engine,
                subject: subject,
                clockAnchor: nil,
                pendingCompletion: completion,
                savedAt: end
            )

            let pending: SyncedFocusTimer
            if cancellationArrivesFirst {
                _ = try FocusCloudSyncStore.claimOwnership(
                    sessionID: sessionA,
                    context: context,
                    deviceID: "device-b",
                    now: end
                )
                try FocusCloudSyncStore.markTerminal(
                    sessionID: sessionA,
                    status: .cancelled,
                    context: context,
                    deviceID: "device-b",
                    at: cancelledAt
                )
                try context.save()
                pending = try FocusCloudSyncStore.upsert(
                    envelope: pendingEnvelope,
                    status: .completionPending,
                    context: context,
                    deviceID: "device-a",
                    claimIfUnowned: false,
                    now: end
                )
            } else {
                pending = try FocusCloudSyncStore.upsert(
                    envelope: pendingEnvelope,
                    status: .completionPending,
                    context: context,
                    deviceID: "device-a",
                    claimIfUnowned: false,
                    now: end
                )
                try context.save()
                _ = try FocusCloudSyncStore.claimOwnership(
                    sessionID: sessionA,
                    context: context,
                    deviceID: "device-b",
                    now: end
                )
                try FocusCloudSyncStore.markTerminal(
                    sessionID: sessionA,
                    status: .cancelled,
                    context: context,
                    deviceID: "device-b",
                    at: cancelledAt
                )
            }
            try context.save()

            XCTAssertEqual(
                pending.ownershipSequence,
                running.ownershipSequence,
                "A completion witness must preserve A's lineage instead of borrowing B's claim"
            )
            XCTAssertEqual(pending.writerDeviceID, "device-a")
            XCTAssertEqual(
                try FocusCloudSyncStore.completionGate(
                    sessionID: sessionA,
                    context: context
                ),
                .open,
                "A cancellation after the scheduled end cannot erase earned evidence"
            )
            XCTAssertEqual(
                try FocusCloudSyncStore.notificationOwner(
                    sessionID: sessionA,
                    context: context
                ),
                "device-b"
            )

            let claims = try FocusCloudSyncStore.claims(
                sessionID: sessionA,
                context: context
            ).map(\.policySnapshot)
            XCTAssertEqual(
                FocusSyncPolicy.completionMaterializationDecision(
                    sessionID: sessionA,
                    existingSessionIDs: [],
                    currentDeviceID: "device-a",
                    claims: claims
                ),
                .rejectedOwnership
            )
            XCTAssertEqual(
                FocusSyncPolicy.completionMaterializationDecision(
                    sessionID: sessionA,
                    existingSessionIDs: [],
                    currentDeviceID: "device-b",
                    claims: claims
                ),
                .insert
            )
        }
    }

    func testCancellationClosesSessionAcrossLaterOwnershipClaim() {
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
            staleOfflineCancellation
        )
    }

    func testSameSessionResolutionDoesNotDependOnCloudDeliveryOrder() {
        let start = Date(timeIntervalSince1970: 1_800_375_000)
        let end = start.addingTimeInterval(1_500)
        let running = snapshot(
            recordID: recordA,
            sessionID: sessionA,
            status: .running,
            startedAt: start,
            scheduledEndAt: end,
            updatedAt: start.addingTimeInterval(300),
            revision: 50,
            ownershipSequence: 4,
            writer: "new-owner"
        )
        let pending = snapshot(
            recordID: recordB,
            sessionID: sessionA,
            status: .completionPending,
            startedAt: start,
            scheduledEndAt: end,
            updatedAt: end,
            revision: 3,
            ownershipSequence: 1,
            writer: "finisher"
        )
        let lateCancellation = snapshot(
            recordID: UUID(),
            sessionID: sessionA,
            status: .cancelled,
            startedAt: start,
            scheduledEndAt: end,
            updatedAt: end.addingTimeInterval(10),
            terminalAt: end.addingTimeInterval(10),
            revision: 99,
            ownershipSequence: 9,
            writer: "late-canceller"
        )

        let permutations = [
            [running, pending, lateCancellation],
            [running, lateCancellation, pending],
            [pending, running, lateCancellation],
            [pending, lateCancellation, running],
            [lateCancellation, running, pending],
            [lateCancellation, pending, running]
        ]
        for values in permutations {
            XCTAssertEqual(
                FocusSyncPolicy.resolveSameSession(values)?.recordID,
                pending.recordID
            )
        }
    }

    func testCompactionKeepsCancellationWitnessNeededByFutureCompletion() {
        let start = Date(timeIntervalSince1970: 1_800_380_000)
        let earlyEnd = start.addingTimeInterval(80)
        let laterEnd = start.addingTimeInterval(100)
        let firstPending = snapshot(
            recordID: recordA,
            sessionID: sessionA,
            status: .completionPending,
            startedAt: start,
            scheduledEndAt: earlyEnd,
            updatedAt: earlyEnd,
            revision: 1,
            writer: "first"
        )
        let cancellation = snapshot(
            recordID: recordB,
            sessionID: sessionA,
            status: .cancelled,
            startedAt: start,
            scheduledEndAt: earlyEnd,
            updatedAt: start.addingTimeInterval(90),
            terminalAt: start.addingTimeInterval(90),
            revision: 2,
            writer: "cancel"
        )
        let laterPending = snapshot(
            recordID: UUID(),
            sessionID: sessionA,
            status: .completionPending,
            startedAt: start,
            scheduledEndAt: laterEnd,
            updatedAt: laterEnd,
            revision: 3,
            writer: "later"
        )

        let firstPageWitnesses = FocusSyncPolicy.compactionWitnesses(
            from: [firstPending, cancellation]
        )
        XCTAssertEqual(Set(firstPageWitnesses.map(\.recordID)), [recordA, recordB])
        XCTAssertEqual(
            FocusSyncPolicy.resolveSameSession(firstPageWitnesses + [laterPending]),
            FocusSyncPolicy.resolveSameSession([
                firstPending,
                cancellation,
                laterPending
            ])
        )
        XCTAssertEqual(
            FocusSyncPolicy.resolveSameSession(firstPageWitnesses + [laterPending]),
            cancellation
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

    func testReleasedDuplicateClaimCannotReviveOldOwnerInPolicy() {
        let instant = Date(timeIntervalSince1970: 1_800_525_000)
        let duplicateID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let staleUnreleasedCopy = FocusOwnershipClaimSnapshot(
            id: duplicateID,
            sessionID: sessionA,
            deviceID: "device-a",
            sequence: 9,
            claimedAt: instant,
            releasedAt: nil
        )
        let releasedCopy = FocusOwnershipClaimSnapshot(
            id: duplicateID,
            sessionID: sessionA,
            deviceID: "device-a",
            sequence: 9,
            claimedAt: instant,
            releasedAt: instant.addingTimeInterval(30)
        )
        let currentOwner = FocusOwnershipClaimSnapshot(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!,
            sessionID: sessionA,
            deviceID: "device-b",
            sequence: 8,
            claimedAt: instant.addingTimeInterval(60),
            releasedAt: nil
        )

        for claims in [
            [staleUnreleasedCopy, releasedCopy, currentOwner],
            [currentOwner, releasedCopy, staleUnreleasedCopy]
        ] {
            XCTAssertEqual(
                FocusSyncPolicy.notificationOwner(for: sessionA, claims: claims),
                "device-b",
                "Any release copy must tombstone every physical copy with the same claim ID"
            )
        }
    }

    @MainActor
    func testStoreReleasedDuplicateClaimCannotReviveOldOwner() throws {
        let container = try focusContainer(named: "FocusCloudSyncReleasedClaimCopy")
        let context = container.mainContext
        let instant = Date(timeIntervalSince1970: 1_800_550_000)
        let duplicateID = UUID(uuidString: "40000000-0000-0000-0000-000000000003")!
        context.insert(FocusTimerDeviceClaim(
            id: duplicateID,
            sessionID: sessionA,
            deviceID: "device-a",
            sequence: 9,
            claimedAt: instant
        ))
        context.insert(FocusTimerDeviceClaim(
            id: duplicateID,
            sessionID: sessionA,
            deviceID: "device-a",
            sequence: 9,
            claimedAt: instant,
            releasedAt: instant.addingTimeInterval(30)
        ))
        context.insert(FocusTimerDeviceClaim(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            sessionID: sessionA,
            deviceID: "device-b",
            sequence: 8,
            claimedAt: instant.addingTimeInterval(60)
        ))
        try context.save()

        XCTAssertEqual(
            try FocusCloudSyncStore.notificationOwner(
                sessionID: sessionA,
                context: context
            ),
            "device-b"
        )
        XCTAssertFalse(try FocusCloudSyncStore.isNotificationOwner(
            sessionID: sessionA,
            context: context,
            deviceID: "device-a"
        ))
    }

    @MainActor
    func testReleaseOutsideFullOwnershipPageCannotAuthorizeANewClaim() throws {
        let container = try focusContainer(named: "FocusCloudSyncTruncatedRelease")
        let context = container.mainContext
        let instant = Date(timeIntervalSince1970: 1_800_550_000)
        let candidateID = UUID()
        for sequence in 2...FocusCloudSyncStore.QueryContract.matchingSessionClaimLimit {
            context.insert(FocusTimerDeviceClaim(
                sessionID: sessionA, deviceID: "released-\(sequence)",
                sequence: sequence, claimedAt: instant,
                releasedAt: instant.addingTimeInterval(30)
            ))
        }
        context.insert(FocusTimerDeviceClaim(
            id: candidateID, sessionID: sessionA, deviceID: "released-candidate",
            sequence: 1, claimedAt: instant.addingTimeInterval(10)
        ))
        // Physical copies need not have matching metadata. Any release of the
        // logical claim tombstones it; the older timestamp puts this evidence
        // deterministically beyond the initial 128-row prefix.
        context.insert(FocusTimerDeviceClaim(
            id: candidateID, sessionID: sessionA, deviceID: "released-candidate",
            sequence: 1, claimedAt: instant,
            releasedAt: instant.addingTimeInterval(30)
        ))
        context.insert(FocusTimerDeviceClaim(
            sessionID: sessionA, deviceID: "actual-owner",
            sequence: 0, claimedAt: instant
        ))
        let timer = try timerRecord(
            sessionID: sessionA, status: .running, start: instant,
            updatedAt: instant, revision: 1, ownershipSequence: 0,
            writer: "actual-owner"
        )
        context.insert(timer)
        try context.save()
        let claimsBefore = try context.fetchCount(FetchDescriptor<FocusTimerDeviceClaim>())
        let recordsBefore = try context.fetchCount(FetchDescriptor<SyncedFocusTimer>())
        let bounded = try FocusCloudSyncStore.claims(sessionID: sessionA, context: context)
        XCTAssertEqual(bounded.count, FocusCloudSyncStore.QueryContract.matchingSessionClaimLimit)
        XCTAssertEqual(FocusSyncPolicy.notificationOwner(
            for: sessionA, claims: bounded.map(\.policySnapshot)
        ), "released-candidate")
        let complete = try context.fetch(FetchDescriptor<FocusTimerDeviceClaim>())
        XCTAssertEqual(FocusSyncPolicy.notificationOwner(
            for: sessionA, claims: complete.map(\.policySnapshot)
        ), "actual-owner")

        let assertBoundedFailure: (Error) -> Void = {
            XCTAssertEqual($0 as? FocusCloudSyncError, .timerHistoryRequiresMaintenance)
        }
        XCTAssertThrowsError(try FocusCloudSyncStore.notificationOwner(
            sessionID: sessionA, context: context
        )) { assertBoundedFailure($0) }
        XCTAssertThrowsError(try FocusCloudSyncStore.claimOwnership(
            sessionID: sessionA, context: context, deviceID: "new-device"
        )) { assertBoundedFailure($0) }
        XCTAssertThrowsError(try FocusCloudSyncStore.upsert(
            envelope: timer.decodedPayload().recoveryEnvelope(adoptedAt: instant),
            status: .running, context: context, deviceID: "new-device",
            claimIfUnowned: true, now: instant
        )) { assertBoundedFailure($0) }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FocusTimerDeviceClaim>()), claimsBefore)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncedFocusTimer>()), recordsBefore)
        XCTAssertFalse(context.hasChanges)
    }

    @MainActor
    func testCompleteReleasedOwnershipHistoryAllowsANewClaim() throws {
        let container = try focusContainer(named: "FocusCloudSyncCompleteReleasedClaims")
        let context = container.mainContext
        let instant = Date(timeIntervalSince1970: 1_800_550_000)
        let id = UUID()
        for releasedAt in [nil, Optional(instant.addingTimeInterval(30))] {
            context.insert(FocusTimerDeviceClaim(
                id: id, sessionID: sessionA, deviceID: "released-device",
                sequence: 8, claimedAt: instant, releasedAt: releasedAt
            ))
        }
        let timer = try timerRecord(
            sessionID: sessionA, status: .running, start: instant,
            updatedAt: instant, revision: 1, ownershipSequence: 8,
            writer: "released-device"
        )
        context.insert(timer)
        try context.save()

        XCTAssertNil(try FocusCloudSyncStore.notificationOwner(sessionID: sessionA, context: context))
        _ = try FocusCloudSyncStore.upsert(
            envelope: timer.decodedPayload().recoveryEnvelope(adoptedAt: instant),
            status: .running, context: context, deviceID: "new-device",
            claimIfUnowned: true, now: instant.addingTimeInterval(60)
        )
        try context.save()
        XCTAssertEqual(try FocusCloudSyncStore.notificationOwner(
            sessionID: sessionA, context: context
        ), "new-device")
        let claims = try FocusCloudSyncStore.claims(sessionID: sessionA, context: context)
        XCTAssertEqual(claims.count, 3)
        XCTAssertEqual(claims.first?.sequence, 9)
    }

    @MainActor
    func testSwiftDataStoreRoundTripPreservesOneLogicalTimerAndClaim() throws {
        let schema = Schema([
            StudySession.self,
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
    func testReconciliationDoesNotDestructivelyCancelAnotherLogicalTimer() throws {
        let schema = Schema([
            StudySession.self,
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
        let completionEvent = try XCTUnwrap(winningEngine.advance(at: end))
        guard case let .focusCompleted(completion) = completionEvent else {
            return XCTFail("Expected completion")
        }
        _ = try FocusCloudSyncStore.upsert(
            envelope: FocusRecoveryEnvelope(
                engine: winningEngine,
                subject: subject,
                clockAnchor: nil,
                pendingCompletion: completion,
                savedAt: end
            ),
            status: .completionPending,
            context: context,
            deviceID: "iphone",
            claimIfUnowned: false,
            now: end
        )
        try FocusCloudSyncStore.markTerminal(
            sessionID: sessionA,
            status: .completed,
            context: context,
            deviceID: "iphone",
            at: end
        )
        try context.save()

        let next = try FocusCloudSyncStore.reconcileActiveTimers(
            context: context,
            deviceID: "reconciler",
            now: end.addingTimeInterval(1)
        )
        XCTAssertEqual(next?.sessionID, sessionB)
        try context.save()

        // A later delivery for the independent session remains recoverable.
        // Read-time selection serializes the UI without writing an irreversible
        // cancellation based on an incomplete CloudKit snapshot.
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
        XCTAssertFalse(allRecords.contains {
            $0.sessionID == sessionB && $0.status == .cancelled
        })
        XCTAssertEqual(
            try FocusCloudSyncStore.canonicalActive(context: context)?.sessionID,
            sessionB
        )
    }

    @MainActor
    func testTerminalWriteFailsWhenNoSharedTimerHistoryExists() throws {
        let schema = Schema([
            StudySession.self,
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

    @MainActor
    func testOldTerminalCannotBeHiddenByMoreThanInteractiveRevisionLimit() throws {
        let container = try focusContainer(named: "FocusCloudSyncOldTerminal")
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_800_800_000)
        let cancelled = try timerRecord(
            sessionID: sessionA,
            status: .cancelled,
            start: start,
            updatedAt: start.addingTimeInterval(10),
            revision: 1,
            ownershipSequence: 0,
            writer: "offline-owner"
        )
        context.insert(cancelled)
        for index in 0..<300 {
            context.insert(try timerRecord(
                sessionID: sessionA,
                status: .running,
                start: start,
                updatedAt: start.addingTimeInterval(100 + TimeInterval(index)),
                revision: index + 2,
                ownershipSequence: 10,
                writer: "stale-revision-\(index)"
            ))
        }
        try context.save()

        XCTAssertTrue(try FocusCloudSyncStore.isSessionClosed(
            sessionID: sessionA,
            context: context
        ))
        let nextStart = start.addingTimeInterval(2_000)
        context.insert(try timerRecord(
            sessionID: sessionB,
            status: .running,
            start: nextStart,
            updatedAt: nextStart,
            revision: 1,
            ownershipSequence: 0,
            writer: "next-device"
        ))
        try context.save()

        XCTAssertEqual(
            try FocusCloudSyncStore.canonicalActive(context: context)?.sessionID,
            sessionB,
            "A closed session's stale raw-row prefix must not hide the next logical timer"
        )
        XCTAssertThrowsError(try FocusCloudSyncStore.claimOwnership(
            sessionID: sessionA,
            context: context,
            deviceID: "new-device"
        )) { error in
            XCTAssertEqual(error as? FocusCloudSyncError, .timerAlreadyTerminal)
        }
    }

    @MainActor
    func testMaterializedStudySessionIsExactClosureSentinelBeforeRevisionLimit() throws {
        let container = try focusContainer(named: "FocusCloudSyncMaterialized")
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_800_900_000)
        context.insert(StudySession(
            id: sessionA,
            startAt: start,
            endAt: start.addingTimeInterval(1_500),
            seconds: 1_500,
            source: .timer,
            grams: StudySession.grams(for: 1_500),
            deviceDayKey: "2026-09-03"
        ))
        for index in 0..<140 {
            context.insert(try timerRecord(
                sessionID: sessionA,
                status: .running,
                start: start,
                updatedAt: start.addingTimeInterval(TimeInterval(index)),
                revision: index + 1,
                ownershipSequence: 2,
                writer: "revision-\(index)"
            ))
        }
        try context.save()

        XCTAssertThrowsError(try FocusCloudSyncStore.claimOwnership(
            sessionID: sessionA,
            context: context,
            deviceID: "new-device"
        )) { error in
            XCTAssertEqual(error as? FocusCloudSyncError, .timerAlreadyTerminal)
        }
    }

    @MainActor
    func testLateCancellationDoesNotCloseEarnedPendingCompletion() throws {
        let container = try focusContainer(named: "FocusCloudSyncLateCancellation")
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_801_000_000)
        let end = start.addingTimeInterval(1_500)
        context.insert(try timerRecord(
            sessionID: sessionA,
            status: .completionPending,
            start: start,
            updatedAt: end,
            revision: 2,
            ownershipSequence: 1,
            writer: "finisher"
        ))
        context.insert(try timerRecord(
            sessionID: sessionA,
            status: .cancelled,
            start: start,
            updatedAt: end.addingTimeInterval(5),
            revision: 3,
            ownershipSequence: 2,
            writer: "late-canceller"
        ))
        try context.save()

        XCTAssertFalse(try FocusCloudSyncStore.isSessionClosed(
            sessionID: sessionA,
            context: context
        ))
        XCTAssertEqual(
            try FocusCloudSyncStore.canonicalActive(context: context)?.status,
            .completionPending
        )
    }

    @MainActor
    func testCompletionGateRejectsCancellationBeforeScheduledEnd() throws {
        let container = try focusContainer(named: "FocusCloudSyncEarlyCancellation")
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_801_050_000)
        let end = start.addingTimeInterval(1_500)
        context.insert(try timerRecord(
            sessionID: sessionA,
            status: .completionPending,
            start: start,
            updatedAt: end,
            revision: 2,
            ownershipSequence: 1,
            writer: "finisher"
        ))
        context.insert(try timerRecord(
            sessionID: sessionA,
            status: .cancelled,
            start: start,
            updatedAt: end.addingTimeInterval(-1),
            revision: 3,
            ownershipSequence: 2,
            writer: "canceller"
        ))
        try context.save()

        XCTAssertEqual(
            try FocusCloudSyncStore.completionGate(
                sessionID: sessionA,
                context: context
            ),
            .cancelledBeforeCompletion
        )
    }

    @MainActor
    func testCompletionGateWaitsForStudySessionAfterCompletedTimerArrives() throws {
        let container = try focusContainer(named: "FocusCloudSyncCompletedAwaitingSession")
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_801_075_000)
        let end = start.addingTimeInterval(1_500)
        context.insert(try timerRecord(
            sessionID: sessionA,
            status: .completed,
            start: start,
            updatedAt: end,
            revision: 3,
            ownershipSequence: 1,
            writer: "finisher"
        ))
        try context.save()

        XCTAssertEqual(
            try FocusCloudSyncStore.completionGate(
                sessionID: sessionA,
                context: context
            ),
            .completedAwaitingSession
        )

        context.insert(StudySession(
            id: sessionA,
            startAt: start,
            endAt: end,
            seconds: 1_500,
            source: .timer,
            grams: StudySession.grams(for: 1_500),
            deviceDayKey: "2026-09-03"
        ))
        try context.save()
        XCTAssertEqual(
            try FocusCloudSyncStore.completionGate(
                sessionID: sessionA,
                context: context
            ),
            .materialized
        )
    }

    @MainActor
    func testPhysicalDuplicateIDReturnsTheResolvedSnapshotNotFetchOrder() throws {
        let duplicateID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let start = Date(timeIntervalSince1970: 1_801_087_000)
        let end = start.addingTimeInterval(1_500)

        for reverseInsertion in [false, true] {
            let container = try focusContainer(
                named: "FocusCloudSyncPhysicalDuplicate-\(reverseInsertion)"
            )
            let context = container.mainContext
            let running = try timerRecord(
                sessionID: sessionA,
                status: .running,
                start: start,
                updatedAt: end.addingTimeInterval(30),
                revision: 9,
                ownershipSequence: 1,
                writer: "newer-running"
            )
            running.id = duplicateID
            let pending = try timerRecord(
                sessionID: sessionA,
                status: .completionPending,
                start: start,
                updatedAt: end,
                revision: 2,
                ownershipSequence: 1,
                writer: "finisher"
            )
            pending.id = duplicateID
            (reverseInsertion ? [pending, running] : [running, pending])
                .forEach { context.insert($0) }
            try context.save()

            let canonical = try XCTUnwrap(
                FocusCloudSyncStore.canonicalActive(context: context)
            )
            XCTAssertEqual(canonical.policySnapshot, pending.policySnapshot)
        }
    }

    func testPayloadRejectsDisagreementBetweenEngineAndPendingCompletion() throws {
        let start = Date(timeIntervalSince1970: 1_801_090_000)
        var engineA = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engineA.startFocus(isPro: false, now: start, sessionID: sessionA)

        var engineB = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engineB.startFocus(isPro: false, now: start, sessionID: sessionB)
        let event = try XCTUnwrap(engineB.advance(at: start.addingTimeInterval(1_500)))
        guard case let .focusCompleted(completionB) = event else {
            return XCTFail("Expected completion")
        }

        XCTAssertThrowsError(try FocusCloudPayload(envelope: FocusRecoveryEnvelope(
            engine: engineA,
            subject: subject,
            clockAnchor: nil,
            pendingCompletion: completionB,
            savedAt: start.addingTimeInterval(1_500)
        ))) { error in
            XCTAssertEqual(error as? FocusCloudSyncError, .invalidPayload)
        }
    }

    func testDecodedRunningPayloadRejectsOutOfRangeDateBeforeSnapshot() throws {
        let start = Date(timeIntervalSince1970: 1_801_091_000)
        let record = try timerRecord(
            sessionID: sessionA,
            status: .running,
            start: start,
            updatedAt: start,
            revision: 1,
            ownershipSequence: 0,
            writer: "hostile-date"
        )
        let hostileEnd = Date(
            timeIntervalSinceReferenceDate: Double.greatestFiniteMagnitude / 4
        )
        try mutateEncodedEngine(in: record) { engine in
            engine["endDate"] = hostileEnd.timeIntervalSinceReferenceDate
        }
        record.scheduledEndAt = hostileEnd

        XCTAssertThrowsError(try record.decodedPayload()) { error in
            XCTAssertEqual(error as? FocusCloudSyncError, .invalidPayload)
        }
    }

    func testDecodedRunningPayloadRejectsOverflowingCustomDuration() throws {
        let start = Date(timeIntervalSince1970: 1_801_091_100)
        let record = try timerRecord(
            sessionID: sessionA,
            status: .running,
            start: start,
            updatedAt: start,
            revision: 1,
            ownershipSequence: 0,
            writer: "hostile-duration"
        )
        try mutateEncodedEngine(in: record) { engine in
            engine["selectedDuration"] = [
                "custom": ["minutes": Int.max]
            ]
        }

        XCTAssertThrowsError(try record.decodedPayload()) { error in
            XCTAssertEqual(error as? FocusCloudSyncError, .invalidPayload)
        }
    }

    func testDecodedRunningPayloadRejectsNearIntegerMaximumCompletionCount() throws {
        let start = Date(timeIntervalSince1970: 1_801_091_150)
        let record = try timerRecord(
            sessionID: sessionA,
            status: .running,
            start: start,
            updatedAt: start,
            revision: 1,
            ownershipSequence: 0,
            writer: "hostile-completion-count"
        )
        try mutateEncodedEngine(in: record) { engine in
            engine["completedFocusCount"] = Int.max - 1
        }

        XCTAssertThrowsError(try record.decodedPayload()) { error in
            XCTAssertEqual(error as? FocusCloudSyncError, .invalidPayload)
        }
    }

    func testDecodedPausedPayloadRejectsUnboundedRemainingBeforeSnapshot() throws {
        let start = Date(timeIntervalSince1970: 1_801_091_200)
        let record = try timerRecord(
            sessionID: sessionA,
            status: .paused,
            start: start,
            updatedAt: start,
            revision: 2,
            ownershipSequence: 0,
            writer: "hostile-remaining"
        )
        try mutateEncodedEngine(in: record) { engine in
            engine["pausedRemaining"] = Double.greatestFiniteMagnitude / 4
        }

        XCTAssertThrowsError(try record.decodedPayload()) { error in
            XCTAssertEqual(error as? FocusCloudSyncError, .invalidPayload)
        }
    }

    func testPendingPayloadRejectsTamperedAwardFields() throws {
        let start = Date(timeIntervalSince1970: 1_801_092_000)
        let end = start.addingTimeInterval(1_500)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: sessionA)
        let event = try XCTUnwrap(engine.advance(at: end))
        guard case let .focusCompleted(completion) = event else {
            return XCTFail("Expected completion")
        }

        let invalidCompletions: [(field: String, value: PomodoroCompletion)] = [
            (
                "grams",
                PomodoroCompletion(
                    sessionID: completion.sessionID,
                    startedAt: completion.startedAt,
                    endedAt: completion.endedAt,
                    observedAt: completion.observedAt,
                    duration: completion.duration,
                    seconds: completion.seconds,
                    grams: completion.grams + 10,
                    source: completion.source
                )
            ),
            (
                "seconds",
                PomodoroCompletion(
                    sessionID: completion.sessionID,
                    startedAt: completion.startedAt,
                    endedAt: completion.endedAt,
                    observedAt: completion.observedAt,
                    duration: completion.duration,
                    seconds: completion.seconds - 60,
                    grams: completion.grams,
                    source: completion.source
                )
            ),
            (
                "scheduled interval",
                PomodoroCompletion(
                    sessionID: completion.sessionID,
                    startedAt: completion.startedAt,
                    endedAt: completion.endedAt.addingTimeInterval(-1),
                    observedAt: completion.observedAt,
                    duration: completion.duration,
                    seconds: completion.seconds,
                    grams: completion.grams,
                    source: completion.source
                )
            ),
            (
                "observation time",
                PomodoroCompletion(
                    sessionID: completion.sessionID,
                    startedAt: completion.startedAt,
                    endedAt: completion.endedAt,
                    observedAt: completion.endedAt.addingTimeInterval(-1),
                    duration: completion.duration,
                    seconds: completion.seconds,
                    grams: completion.grams,
                    source: completion.source
                )
            ),
            (
                "duration",
                PomodoroCompletion(
                    sessionID: completion.sessionID,
                    startedAt: completion.startedAt,
                    endedAt: completion.startedAt.addingTimeInterval(3_600),
                    observedAt: completion.startedAt.addingTimeInterval(3_600),
                    duration: .sixtyMinutes,
                    seconds: 3_600,
                    grams: 600,
                    source: completion.source
                )
            ),
            (
                "source",
                PomodoroCompletion(
                    sessionID: completion.sessionID,
                    startedAt: completion.startedAt,
                    endedAt: completion.endedAt,
                    observedAt: completion.observedAt,
                    duration: completion.duration,
                    seconds: completion.seconds,
                    grams: completion.grams,
                    source: .manual
                )
            )
        ]

        for invalid in invalidCompletions {
            XCTAssertThrowsError(
                try pendingTimerRecord(
                    engine: engine,
                    completion: invalid.value,
                    savedAt: invalid.value.observedAt,
                    writer: "device-a"
                ),
                "Expected \(invalid.field) tampering to be rejected"
            ) { error in
                XCTAssertEqual(
                    error as? FocusCloudSyncError,
                    .invalidPayload,
                    invalid.field
                )
            }
        }
    }

    func testDemotedCompletionSourceRemainsValidWhenFrozenByEngine() throws {
        let start = Date(timeIntervalSince1970: 1_801_093_000)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: sessionA)
        try engine.demoteCurrentFocus()
        let end = try XCTUnwrap(engine.endDate)
        let event = try XCTUnwrap(engine.advance(at: end))
        guard case let .focusCompleted(completion) = event else {
            return XCTFail("Expected completion")
        }

        XCTAssertEqual(completion.source, .timerDemoted)
        XCTAssertNoThrow(try pendingTimerRecord(
            engine: engine,
            completion: completion,
            savedAt: end,
            writer: "device-a"
        ))
    }

    @MainActor
    func testCanonicalActiveSkipsMismatchedPayloadWithoutHidingLaterTimer() throws {
        let start = Date(timeIntervalSince1970: 1_801_095_000)

        for status in [SyncedFocusStatus.running, .completionPending] {
            let container = try focusContainer(
                named: "FocusCloudSyncMismatchedPayload-\(status.rawValue)"
            )
            let context = container.mainContext
            let corrupt = try timerRecord(
                sessionID: sessionB,
                status: status,
                start: start,
                updatedAt: start,
                revision: 1,
                ownershipSequence: 0,
                writer: "corrupt-copy"
            )
            // Simulate a malformed CloudKit copy: policy identity A carries a
            // payload whose engine still belongs to B.
            corrupt.sessionID = sessionA
            context.insert(corrupt)
            let valid = try timerRecord(
                sessionID: sessionB,
                status: .running,
                start: start.addingTimeInterval(30),
                updatedAt: start.addingTimeInterval(30),
                revision: 1,
                ownershipSequence: 0,
                writer: "valid-device"
            )
            context.insert(valid)
            try context.save()

            XCTAssertThrowsError(try corrupt.decodedPayload()) { error in
                XCTAssertEqual(error as? FocusCloudSyncError, .invalidPayload)
            }
            XCTAssertEqual(
                try FocusCloudSyncStore.canonicalActive(context: context)?.sessionID,
                sessionB
            )
        }
    }

    @MainActor
    func testCanonicalActiveSkipsCorruptIndexedTimesWithoutChangingRacePolicy() throws {
        let start = Date(timeIntervalSince1970: 1_801_097_000)

        for field in ["startedAt", "scheduledEndAt"] {
            let container = try focusContainer(
                named: "FocusCloudSyncMismatchedIndex-\(field)"
            )
            let context = container.mainContext
            let corrupt = try timerRecord(
                sessionID: sessionA,
                status: .completionPending,
                start: start,
                updatedAt: start.addingTimeInterval(1_500),
                revision: 2,
                ownershipSequence: 1,
                writer: "corrupt-copy"
            )
            if field == "startedAt" {
                corrupt.startedAt = start.addingTimeInterval(-86_400)
            } else {
                // A forged scheduled boundary could otherwise reverse the
                // pending-completion versus cancellation decision.
                corrupt.scheduledEndAt = start.addingTimeInterval(1)
            }
            context.insert(corrupt)
            let valid = try timerRecord(
                sessionID: sessionB,
                status: .running,
                start: start.addingTimeInterval(30),
                updatedAt: start.addingTimeInterval(30),
                revision: 1,
                ownershipSequence: 0,
                writer: "valid-device"
            )
            context.insert(valid)
            try context.save()

            XCTAssertThrowsError(try corrupt.decodedPayload()) { error in
                XCTAssertEqual(error as? FocusCloudSyncError, .invalidPayload)
            }
            XCTAssertEqual(
                try FocusCloudSyncStore.canonicalActive(context: context)?.sessionID,
                sessionB
            )
        }
    }

    @MainActor
    func testCanonicalScanPasses129CorruptSingletonsOnSQLiteWithinBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FocusCloudSyncCorruptScan-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let container = try focusContainer(
            named: "FocusCloudSyncCorruptScan",
            url: directory.appendingPathComponent("Focus.store")
        )
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_801_098_000)
        for index in 0..<129 {
            let corrupt = try timerRecord(
                sessionID: sessionB,
                status: index.isMultiple(of: 2) ? .running : .completionPending,
                start: start.addingTimeInterval(TimeInterval(index)),
                updatedAt: start.addingTimeInterval(TimeInterval(index)),
                revision: 1,
                ownershipSequence: 0,
                writer: "corrupt-\(index)"
            )
            repeat { corrupt.sessionID = UUID() } while corrupt.sessionID == sessionB
            context.insert(corrupt)
        }
        let valid = try timerRecord(
            sessionID: sessionB,
            status: .running,
            start: start.addingTimeInterval(200),
            updatedAt: start.addingTimeInterval(200),
            revision: 1,
            ownershipSequence: 0,
            writer: "valid-device"
        )
        context.insert(valid)
        try context.save()

        let began = ContinuousClock.now
        let canonical = try FocusCloudSyncStore.canonicalActive(context: context)
        let elapsed = began.duration(to: .now)
        XCTAssertEqual(canonical?.sessionID, sessionB)
        XCTAssertLessThan(
            elapsed,
            .seconds(5),
            "The bounded MainActor integrity scan must remain interactive on SQLite."
        )
    }

    @MainActor
    func testCanonicalScanFailsClosedAfter256CorruptSingletons() throws {
        let container = try focusContainer(named: "FocusCloudSyncCorruptScanCeiling")
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_801_099_000)
        for index in 0..<257 {
            let corrupt = try timerRecord(
                sessionID: sessionB,
                status: .running,
                start: start.addingTimeInterval(TimeInterval(index)),
                updatedAt: start.addingTimeInterval(TimeInterval(index)),
                revision: 1,
                ownershipSequence: 0,
                writer: "corrupt-\(index)"
            )
            repeat { corrupt.sessionID = UUID() } while corrupt.sessionID == sessionB
            context.insert(corrupt)
        }
        context.insert(try timerRecord(
            sessionID: sessionB,
            status: .running,
            start: start.addingTimeInterval(300),
            updatedAt: start.addingTimeInterval(300),
            revision: 1,
            ownershipSequence: 0,
            writer: "valid-device"
        ))
        try context.save()

        XCTAssertThrowsError(try FocusCloudSyncStore.canonicalActive(context: context)) {
            XCTAssertEqual(
                $0 as? FocusCloudSyncError,
                .timerHistoryRequiresMaintenance
            )
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

    func testDeviceIdentityIsSeparatedByVerifiedAppleAccountNamespace() throws {
        let suite = "FocusCloudSyncTests.account-device.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        AccountScopedLocalState.beginCloudBoundary(
            standardDefaults: defaults,
            appGroupDefaults: nil
        )
        let namespaceA = AccountDataNamespace()
        let namespaceB = AccountDataNamespace()
        try AccountScopedLocalState.activate(
            try XCTUnwrap(ActiveAccountLocalBinding(
                namespace: namespaceA,
                accountFingerprint: String(repeating: "a", count: 64)
            )),
            standardDefaults: defaults,
            appGroupDefaults: nil
        )
        let accountADeviceID = FocusDeviceIdentity.current(defaults: defaults)

        try AccountScopedLocalState.activate(
            try XCTUnwrap(ActiveAccountLocalBinding(
                namespace: namespaceB,
                accountFingerprint: String(repeating: "b", count: 64)
            )),
            standardDefaults: defaults,
            appGroupDefaults: nil
        )
        let accountBDeviceID = FocusDeviceIdentity.current(defaults: defaults)
        XCTAssertNotEqual(accountADeviceID, accountBDeviceID)

        try AccountScopedLocalState.activate(
            try XCTUnwrap(ActiveAccountLocalBinding(
                namespace: namespaceA,
                accountFingerprint: String(repeating: "a", count: 64)
            )),
            standardDefaults: defaults,
            appGroupDefaults: nil
        )
        XCTAssertEqual(
            FocusDeviceIdentity.current(defaults: defaults),
            accountADeviceID
        )
    }

    @MainActor
    func testMoreThan64PauseCyclesStillSyncAdoptAndClose() throws {
        for terminalStatus in [SyncedFocusStatus.completed, .cancelled] {
            let container = try focusContainer(named: "FocusHistoryTransitions-\(terminalStatus)")
            let context = container.mainContext
            let start = Date.now.addingTimeInterval(-600)
            var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
            try engine.startFocus(isPro: false, now: start, sessionID: sessionA)
            var writer = "device-a"
            func publish(_ status: SyncedFocusStatus, at date: Date) throws {
                _ = try FocusCloudSyncStore.upsert(
                    envelope: FocusRecoveryEnvelope(
                        engine: engine, subject: subject, clockAnchor: nil,
                        pendingCompletion: nil, savedAt: date
                    ),
                    status: status, context: context, deviceID: writer,
                    claimIfUnowned: true, now: date
                )
                try context.save()
            }
            try publish(.running, at: start)
            for index in 0 ..< 65 {
                let pausedAt = start.addingTimeInterval(1 + Double(index) * 2)
                try engine.pause(at: pausedAt)
                try publish(.paused, at: pausedAt)
                let resumedAt = pausedAt.addingTimeInterval(0.5)
                try engine.resume(at: resumedAt)
                try publish(.running, at: resumedAt)
            }
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncedFocusTimer>()), 131)
            let latest = try XCTUnwrap(FocusCloudSyncStore.canonicalActive(context: context))
            XCTAssertEqual(latest.status, .running)
            XCTAssertEqual(latest.revision, 131)

            _ = try FocusCloudSyncStore.claimOwnership(
                sessionID: sessionA, context: context, deviceID: "device-b",
                expectedRecordID: latest.id, expectedRevision: latest.revision,
                expectedOwnershipSequence: latest.ownershipSequence
            )
            try context.save()
            writer = "device-b"
            try publish(.running, at: start.addingTimeInterval(200))
            XCTAssertEqual(try FocusCloudSyncStore.notificationOwner(
                sessionID: sessionA, context: context
            ), writer)

            let end = try XCTUnwrap(engine.endDate)
            if terminalStatus == .completed {
                guard case let .focusCompleted(completion)? = engine.advance(at: end) else {
                    return XCTFail("Expected earned completion after repeated pauses")
                }
                _ = try FocusCloudSyncStore.upsert(
                    envelope: FocusRecoveryEnvelope(
                        engine: engine, subject: subject, clockAnchor: nil,
                        pendingCompletion: completion, savedAt: end
                    ),
                    status: .completionPending, context: context, deviceID: writer,
                    claimIfUnowned: false, now: end
                )
                context.insert(FocusCompletionSessionFactory.normalSession(
                    completion: completion, subject: nil, subjectSnapshot: subject,
                    dataEpochID: nil
                ))
            }
            try FocusCloudSyncStore.markTerminal(
                sessionID: sessionA, status: terminalStatus, context: context,
                deviceID: writer, at: end
            )
            try context.save()
            XCTAssertTrue(try FocusCloudSyncStore.isSessionClosed(
                sessionID: sessionA, context: context
            ))
            XCTAssertNil(try FocusCloudSyncStore.canonicalActive(context: context))
            let rows = try context.fetch(FetchDescriptor<SyncedFocusTimer>())
            XCTAssertEqual(rows.count, terminalStatus == .completed ? 134 : 133)
            XCTAssertEqual(rows.filter { $0.status == terminalStatus }.count, 1)
        }
    }

    @MainActor
    func testPagedHistoryValidatesDuplicatePayloadsAcrossPageBoundary() throws {
        for hasConflict in [false, true] {
            let container = try focusContainer(named: "FocusHistoryBoundary-\(hasConflict)")
            let context = container.mainContext
            let start = Date.now.addingTimeInterval(-600)
            for index in 0 ..< 127 {
                let row = try timerRecord(
                    sessionID: sessionA, status: .running, start: start,
                    updatedAt: start, revision: index + 1, ownershipSequence: 0,
                    writer: "device-a"
                )
                row.id = historyRecordID(index)
                context.insert(row)
            }
            let first = try timerRecord(
                sessionID: sessionA, status: .running, start: start,
                updatedAt: start, revision: 1, ownershipSequence: 0, writer: "old-device"
            )
            let second = try timerRecord(
                sessionID: sessionA, status: .running, start: start,
                updatedAt: start, revision: 1, ownershipSequence: 0, writer: "old-device"
            )
            first.id = historyRecordID(127)
            second.id = first.id
            second.payloadData = first.payloadData
            var object = try XCTUnwrap(JSONSerialization.jsonObject(
                with: second.payloadData
            ) as? [String: Any])
            if hasConflict {
                var subjectObject = try XCTUnwrap(object["subject"] as? [String: Any])
                subjectObject["name"] = "Different valid subject payload"
                object["subject"] = subjectObject
            }
            second.payloadData = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .prettyPrinted]
            )
            _ = try second.decodedPayload()
            context.insert(first)
            context.insert(second)
            let winner = try timerRecord(
                sessionID: sessionA, status: .running, start: start,
                updatedAt: start, revision: 1, ownershipSequence: 7, writer: "new-device"
            )
            winner.id = historyRecordID(128)
            context.insert(winner)
            try context.save()
            let originalBytes = second.payloadData

            if hasConflict {
                XCTAssertThrowsError(try FocusCloudSyncStore.claimOwnership(
                    sessionID: sessionA, context: context, deviceID: "reader"
                )) {
                    XCTAssertEqual($0 as? FocusCloudSyncError, .invalidPayload)
                }
            } else {
                XCTAssertEqual(try FocusCloudSyncStore.canonicalActive(context: context)?.id,
                               winner.id)
                _ = try FocusCloudSyncStore.claimOwnership(
                    sessionID: sessionA, context: context, deviceID: "reader"
                )
            }
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncedFocusTimer>()), 130)
            XCTAssertEqual(second.payloadData, originalBytes)
        }
    }

    @MainActor
    func testPagedHistoryGroupsCanonicallyEquivalentWriterIDs() throws {
        let decomposed = "x-e\u{301}"
        let precomposed = "x-\u{e9}"
        let distinct = "x-e\u{34f}\u{301}"
        XCTAssertEqual(decomposed, precomposed)
        XCTAssertNotEqual(decomposed, distinct)
        for persistFirst in [false, true] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("FocusHistoryUnicode-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let container = try focusContainer(
                named: "FocusHistoryUnicode",
                url: directory.appendingPathComponent("history.store")
            )
            let context = container.mainContext
            context.autosaveEnabled = false
            let start = Date.now.addingTimeInterval(-600)
            let template = try timerRecord(
                sessionID: sessionA, status: .running, start: start,
                updatedAt: start, revision: 1, ownershipSequence: 0,
                writer: decomposed
            )
            for writer in [decomposed, distinct, precomposed] {
                let row = try timerRecord(
                    sessionID: sessionA, status: .running, start: start,
                    updatedAt: start, revision: 1, ownershipSequence: 0, writer: writer
                )
                row.id = template.id
                row.payloadData = template.payloadData
                if writer.utf8.elementsEqual(precomposed.utf8) {
                    var object = try XCTUnwrap(JSONSerialization.jsonObject(
                        with: row.payloadData
                    ) as? [String: Any])
                    object["savedAt"] = start.addingTimeInterval(1).timeIntervalSinceReferenceDate
                    row.payloadData = try JSONSerialization.data(withJSONObject: object)
                }
                _ = try row.decodedPayload()
                context.insert(row)
            }
            if persistFirst { try context.save() }
            // Finder-style collation can place the distinct writer between
            // two Swift-equal snapshots, hiding their divergent payloads from
            // adjacent-row validation. Check SQLite and pending-row ordering.
            XCTAssertThrowsError(try FocusCloudSyncStore.claimOwnership(
                sessionID: sessionA, context: context, deviceID: "reader"
            )) {
                XCTAssertEqual($0 as? FocusCloudSyncError, .invalidPayload)
            }
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncedFocusTimer>()), 3)
        }
    }

    @MainActor
    func testPagedHistoryValidatesUnsavedPhysicalCopiesBeyondOnePage() throws {
        for hasConflict in [false, true] {
            let container = try focusContainer(named: "FocusHistoryPendingCopies-\(hasConflict)")
            let context = container.mainContext
            context.autosaveEnabled = false
            let start = Date.now.addingTimeInterval(-600)
            let source = try timerRecord(
                sessionID: sessionA, status: .running, start: start,
                updatedAt: start, revision: 1, ownershipSequence: 0, writer: "device-a"
            )
            source.id = historyRecordID(0)
            for index in 0 ..< 130 {
                let copy = try timerRecord(
                    sessionID: sessionA, status: .running, start: start,
                    updatedAt: start, revision: 1, ownershipSequence: 0, writer: "device-a"
                )
                copy.id = source.id
                copy.payloadData = source.payloadData
                if hasConflict, index == 129 {
                    var object = try XCTUnwrap(JSONSerialization.jsonObject(
                        with: copy.payloadData
                    ) as? [String: Any])
                    object["savedAt"] = start.addingTimeInterval(1).timeIntervalSinceReferenceDate
                    copy.payloadData = try JSONSerialization.data(withJSONObject: object)
                }
                context.insert(copy)
            }
            if hasConflict {
                XCTAssertThrowsError(try FocusCloudSyncStore.claimOwnership(
                    sessionID: sessionA, context: context, deviceID: "reader"
                )) {
                    XCTAssertEqual($0 as? FocusCloudSyncError, .invalidPayload)
                }
            } else {
                XCTAssertEqual(try FocusCloudSyncStore.canonicalActive(context: context)?.id,
                               source.id)
            }
            XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncedFocusTimer>()), 130)
        }
    }

    @MainActor
    func testPagedHistoryBoundsDistinctSnapshotCollisionsWithinOneEventID() throws {
        let container = try focusContainer(named: "FocusHistoryEventCollisions")
        let context = container.mainContext
        let start = Date.now.addingTimeInterval(-600)
        for index in 0 ..< 129 {
            let row = try timerRecord(
                sessionID: sessionA, status: .running, start: start,
                updatedAt: start, revision: index + 1, ownershipSequence: 0,
                writer: "device-a"
            )
            // Normal state transitions have different UUIDs. This fixture is
            // a bounded failure for conflicting copies of one physical event.
            row.id = historyRecordID(0)
            context.insert(row)
        }
        try context.save()
        XCTAssertThrowsError(try FocusCloudSyncStore.claimOwnership(
            sessionID: sessionA, context: context, deviceID: "reader"
        )) {
            XCTAssertEqual($0 as? FocusCloudSyncError, .timerHistoryRequiresMaintenance)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncedFocusTimer>()), 129)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FocusTimerDeviceClaim>()), 0)
    }

    @MainActor
    func testPagedHistoryRejectsCorruptNonwinningRearRevision() throws {
        let container = try focusContainer(named: "FocusHistoryRearCorruption")
        let context = container.mainContext
        let start = Date.now.addingTimeInterval(-600)
        for index in 0 ..< 260 {
            let row = try timerRecord(
                sessionID: sessionA, status: .running, start: start,
                updatedAt: start, revision: 1,
                ownershipSequence: index == 0 ? 7 : 0, writer: "device-a"
            )
            row.id = historyRecordID(index)
            if index == 259 { row.payloadData = Data([0xFF]) }
            context.insert(row)
        }
        try context.save()
        XCTAssertThrowsError(try FocusCloudSyncStore.claimOwnership(
            sessionID: sessionA, context: context, deviceID: "reader"
        )) {
            XCTAssertEqual($0 as? FocusCloudSyncError, .invalidPayload)
        }
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncedFocusTimer>()), 260)
    }

    @MainActor
    func testThousandRevisionSQLiteHistoryRemainsUsableAndRetainsMaximumRevision() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FocusHistoryBenchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try focusContainer(
            named: "FocusHistoryBenchmark", url: directory.appendingPathComponent("history.store")
        )
        let context = container.mainContext
        let start = Date.now.addingTimeInterval(-600)
        for index in 0 ..< 1_000 {
            let row = try timerRecord(
                sessionID: sessionA, status: .running, start: start,
                updatedAt: start.addingTimeInterval(Double(index)), revision: index + 1,
                ownershipSequence: index == 0 ? 7 : 0, writer: "device-a"
            )
            row.id = historyRecordID(index)
            context.insert(row)
        }
        context.insert(FocusTimerDeviceClaim(
            sessionID: sessionA, deviceID: "device-a", sequence: 7, claimedAt: start
        ))
        try context.save()
        // A fresh context ensures this also measures SQLite reads and decoding,
        // rather than relying solely on the models inserted above.
        let reader = ModelContext(container)
        let beganAt = ProcessInfo.processInfo.systemUptime
        let winner = try XCTUnwrap(FocusCloudSyncStore.canonicalActive(context: reader))
        XCTAssertEqual(winner.id, historyRecordID(0))
        XCTAssertEqual(winner.revision, 1)
        _ = try FocusCloudSyncStore.claimOwnership(
            sessionID: sessionA, context: reader, deviceID: "device-b"
        )
        try FocusCloudSyncStore.markTerminal(
            sessionID: sessionA, status: .cancelled, context: reader,
            deviceID: "device-b", at: start.addingTimeInterval(1_001)
        )
        try reader.save()
        let elapsed = ProcessInfo.processInfo.systemUptime - beganAt
        XCTAssertLessThan(elapsed, 10, "Three complete 1,000-row scans took \(elapsed) seconds")
        let cancelled = SyncedFocusStatus.cancelled.rawValue
        let terminal = try XCTUnwrap(reader.fetch(FetchDescriptor<SyncedFocusTimer>(
            predicate: #Predicate { $0.statusRaw == cancelled }
        )).first)
        XCTAssertEqual(terminal.revision, 1_001,
                       "The next revision must exceed even a discarded nonwinning revision")
        XCTAssertEqual(terminal.ownershipSequence, 8)
        XCTAssertEqual(try reader.fetchCount(FetchDescriptor<SyncedFocusTimer>()), 1_001)
    }

    @MainActor
    func testOwnershipQueriesStayBoundedAndExactWithLifetimeNoise() throws {
        let schema = Schema([
            StudySession.self,
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

    @MainActor
    func testOwnershipWinnerMatchesFullPolicyBeyondQueryLimit() throws {
        let container = try focusContainer(named: "FocusCloudSyncClaimTie")
        let context = container.mainContext
        let instant = Date(timeIntervalSince1970: 1_801_100_000)
        var snapshots: [FocusOwnershipClaimSnapshot] = []
        for index in 0..<129 {
            let deviceID = index == 128 ? "zzzz-policy-winner" : "device-\(index)"
            let id = index == 128
                ? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                : UUID()
            let row = FocusTimerDeviceClaim(
                id: id,
                sessionID: sessionA,
                deviceID: deviceID,
                sequence: 7,
                claimedAt: instant
            )
            snapshots.append(row.policySnapshot)
            context.insert(row)
        }
        try context.save()

        let bounded = try FocusCloudSyncStore.claims(
            sessionID: sessionA,
            context: context
        ).map(\.policySnapshot)
        XCTAssertLessThanOrEqual(
            bounded.count,
            FocusCloudSyncStore.QueryContract.matchingSessionClaimLimit
        )
        XCTAssertEqual(
            FocusSyncPolicy.notificationOwner(for: sessionA, claims: bounded),
            FocusSyncPolicy.notificationOwner(for: sessionA, claims: snapshots)
        )
        XCTAssertEqual(
            try FocusCloudSyncStore.notificationOwner(
                sessionID: sessionA,
                context: context
            ),
            "zzzz-policy-winner"
        )
    }

    private func historyRecordID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", index))!
    }

    @MainActor
    private func insertTimerHistory(
        count: Int, context: ModelContext, start: Date, writer: String
    ) throws {
        for index in 0 ..< count {
            context.insert(try timerRecord(
                sessionID: sessionA, status: .running, start: start,
                updatedAt: start.addingTimeInterval(Double(index)),
                revision: index + 1, ownershipSequence: 0, writer: writer
            ))
        }
        try context.save()
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

    @MainActor
    private func focusContainer(
        named name: String,
        url: URL? = nil
    ) throws -> ModelContainer {
        let schema = Schema([
            StudySession.self,
            ActivityResetMarker.self,
            SyncedFocusTimer.self,
            FocusTimerDeviceClaim.self
        ])
        let configuration: ModelConfiguration
        if let url {
            configuration = ModelConfiguration(
                name,
                schema: schema,
                url: url,
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                name,
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    private func timerRecord(
        sessionID: UUID,
        status: SyncedFocusStatus,
        start: Date,
        updatedAt: Date,
        revision: Int,
        ownershipSequence: Int,
        writer: String
    ) throws -> SyncedFocusTimer {
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: sessionID)
        var pendingCompletion: PomodoroCompletion? = nil
        if status == .completionPending || status == .completed {
            let event = try XCTUnwrap(
                engine.advance(at: start.addingTimeInterval(1_500))
            )
            guard case let .focusCompleted(completion) = event else {
                throw FocusCloudSyncError.invalidPayload
            }
            pendingCompletion = completion
        } else if status == .paused {
            try engine.pause(at: start.addingTimeInterval(1))
        }
        let payload = try FocusCloudPayload(envelope: FocusRecoveryEnvelope(
            engine: engine,
            subject: subject,
            clockAnchor: nil,
            pendingCompletion: pendingCompletion,
            savedAt: updatedAt
        ))
        return try SyncedFocusTimer(
            sessionID: sessionID,
            status: status,
            payload: payload,
            updatedAt: updatedAt,
            revision: revision,
            ownershipSequence: ownershipSequence,
            writerDeviceID: writer
        )
    }

    private func pendingTimerRecord(
        engine: PomodoroEngine,
        completion: PomodoroCompletion,
        savedAt: Date,
        writer: String
    ) throws -> SyncedFocusTimer {
        let payload = try FocusCloudPayload(envelope: FocusRecoveryEnvelope(
            engine: engine,
            subject: subject,
            clockAnchor: nil,
            pendingCompletion: completion,
            savedAt: savedAt
        ))
        return try SyncedFocusTimer(
            sessionID: completion.sessionID,
            status: .completionPending,
            payload: payload,
            updatedAt: savedAt,
            revision: 2,
            ownershipSequence: 0,
            writerDeviceID: writer
        )
    }

    private func mutateEncodedEngine(
        in record: SyncedFocusTimer,
        mutation: (inout [String: Any]) -> Void
    ) throws {
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: record.payloadData)
                as? [String: Any]
        )
        var engine = try XCTUnwrap(payload["engine"] as? [String: Any])
        mutation(&engine)
        payload["engine"] = engine
        record.payloadData = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        )
    }
}
