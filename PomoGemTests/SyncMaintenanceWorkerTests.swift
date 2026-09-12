import AVFoundation
import Foundation
import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class SyncMaintenanceWorkerTests: XCTestCase {
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

    func testLaunchVerificationOnlyCoversRemoteImportMode() {
        XCTAssertTrue(
            SyncMaintenanceLaunchPolicy.requiresInitialVerificationSweep(
                for: .cloudKit
            )
        )
        for localMode: PersistenceLaunchMode in [
            .inMemoryPreview, .persistentSimulator, .localOnly
        ] {
            XCTAssertFalse(
                SyncMaintenanceLaunchPolicy.requiresInitialVerificationSweep(
                    for: localMode
                )
            )
        }
    }

    func testForegroundDrainContinuesAcrossEveryTabAfterGrace() {
        for tab: AppTab in [.jar, .log, .settings] {
            XCTAssertTrue(
                SyncMaintenanceLaunchPolicy.permitsForegroundDrain(on: tab)
            )
        }
    }

    func testIncompleteHomeSessionMaintenanceRoutesOnlyToLocalOnly() {
        XCTAssertEqual(
            LocalSessionMaintenanceRoutingPolicy.maintenanceKind(
                requestIsActive: true,
                persistenceMode: .localOnly
            ),
            .sessions
        )
        for mode: PersistenceLaunchMode in [
            .cloudKit,
            .inMemoryPreview,
            .persistentSimulator
        ] {
            XCTAssertNil(LocalSessionMaintenanceRoutingPolicy.maintenanceKind(
                requestIsActive: true,
                persistenceMode: mode
            ))
        }
        XCTAssertNil(LocalSessionMaintenanceRoutingPolicy.maintenanceKind(
            requestIsActive: false,
            persistenceMode: .localOnly
        ))
    }

    func testEarlyHomeMaintenanceRequestIsCaughtUpOnceAfterFirstFrame() {
        var gate = LocalSessionMaintenanceRequestGate()
        var checkpoint = SyncMaintenanceCheckpoint()

        XCTAssertNil(gate.consume(
            requestIsActive: true,
            firstFrameIsPresented: false,
            persistenceMode: .localOnly
        ))
        XCTAssertFalse(gate.hasConsumedProcessRequest)
        let caughtUpKind = gate.consume(
            requestIsActive: true,
            firstFrameIsPresented: true,
            persistenceMode: .localOnly
        )
        XCTAssertEqual(caughtUpKind, .sessions)
        if let caughtUpKind { checkpoint.enqueue(caughtUpKind) }
        XCTAssertTrue(gate.hasConsumedProcessRequest)
        let replayKind = gate.consume(
            requestIsActive: true,
            firstFrameIsPresented: true,
            persistenceMode: .localOnly
        )
        XCTAssertNil(replayKind)
        if let replayKind { checkpoint.enqueue(replayKind) }
        XCTAssertEqual(checkpoint.generation(for: .sessions), 1)
    }

    func testRelaunchedHomeHintClaimsPendingSessionWithoutRestart() throws {
        let retryAt = Date(timeIntervalSince1970: 1_800_000_000)
        let cursor = SyncMaintenanceCursor(
            observedWinningEpochID: UUID(),
            phase: 2,
            lastLogicalID: UUID(),
            offset: 384,
            payload: Data("pending-session-progress".utf8)
        )
        var checkpoint = SyncMaintenanceCheckpoint()
        checkpoint.enqueue(.sessions)
        let request = try XCTUnwrap(checkpoint.nextRequest(now: retryAt))
        XCTAssertEqual(request.kind, .sessions)
        XCTAssertTrue(checkpoint.apply(.retry(
            request: request,
            cursor: cursor,
            audit: SyncMaintenanceFetchAudit(),
            category: "transient-session-retry"
        ), now: retryAt))

        // Round-trip models the checkpoint loaded by a newly launched Root.
        let persisted = try JSONEncoder().encode(checkpoint)
        var relaunched = try JSONDecoder().decode(
            SyncMaintenanceCheckpoint.self,
            from: persisted
        )
        let beforeHint = relaunched
        var gate = LocalSessionMaintenanceRequestGate()
        let hintedKind = try XCTUnwrap(gate.consume(
            requestIsActive: true,
            firstFrameIsPresented: true,
            persistenceMode: .localOnly
        ))

        XCTAssertEqual(hintedKind, .sessions)
        XCTAssertTrue(relaunched.mergeSessionRepairPipeline())
        XCTAssertEqual(
            relaunched.pendingKinds,
            beforeHint.pendingKinds
        )
        XCTAssertEqual(
            relaunched.generation(for: .sessions),
            beforeHint.generation(for: .sessions)
        )
        XCTAssertEqual(relaunched.nextRequest(
            now: retryAt.addingTimeInterval(1)
        )?.cursor, cursor)
        XCTAssertEqual(
            relaunched.retryState(for: .sessions),
            beforeHint.retryState(for: .sessions)
        )
        XCTAssertEqual(relaunched.homeSessionRepairPipelineIsActive, true)

        let persistedClaim = try JSONEncoder().encode(relaunched)
        var secondRelaunch = try JSONDecoder().decode(
            SyncMaintenanceCheckpoint.self,
            from: persistedClaim
        )
        let beforeSecondHint = secondRelaunch
        XCTAssertFalse(secondRelaunch.mergeSessionRepairPipeline())
        XCTAssertEqual(secondRelaunch, beforeSecondHint)
    }

    func testRelaunchedHomeHintMergesAroundPendingAggregatePipeline() throws {
        let retryAt = Date(timeIntervalSince1970: 1_800_000_000)
        let cursor = SyncMaintenanceCursor(
            observedWinningEpochID: UUID(),
            phase: 4,
            lastLogicalID: UUID(),
            offset: 768,
            payload: Data("pending-aggregate-progress".utf8)
        )
        var checkpoint = SyncMaintenanceCheckpoint()
        XCTAssertTrue(checkpoint.mergeSessionRepairPipeline())
        for expectedKind: SyncMaintenanceKind in [
            .sessions,
            .focusFairness,
            .gacha,
            .subjects,
            .strata
        ] {
            let request = try XCTUnwrap(
                checkpoint.nextRequest(now: retryAt)
            )
            XCTAssertEqual(request.kind, expectedKind)
            XCTAssertTrue(checkpoint.apply(.completed(
                request: request,
                audit: SyncMaintenanceFetchAudit()
            )))
        }
        XCTAssertFalse(checkpoint.isPending(.sessions))

        let aggregateRequest = try XCTUnwrap(
            checkpoint.nextRequest(now: retryAt)
        )
        XCTAssertEqual(aggregateRequest.kind, .aggregates)
        XCTAssertTrue(checkpoint.apply(.retry(
            request: aggregateRequest,
            cursor: cursor,
            audit: SyncMaintenanceFetchAudit(),
            category: "transient-aggregate-retry"
        ), now: retryAt))

        let persisted = try JSONEncoder().encode(checkpoint)
        var relaunched = try JSONDecoder().decode(
            SyncMaintenanceCheckpoint.self,
            from: persisted
        )
        let beforeHint = relaunched
        var gate = LocalSessionMaintenanceRequestGate()
        XCTAssertEqual(gate.consume(
            requestIsActive: true,
            firstFrameIsPresented: true,
            persistenceMode: .localOnly
        ), .sessions)

        XCTAssertFalse(relaunched.mergeSessionRepairPipeline())
        XCTAssertEqual(relaunched, beforeHint)
        XCTAssertEqual(relaunched.pendingKinds, [.aggregates])
        XCTAssertEqual(
            relaunched.generation(for: .aggregates),
            beforeHint.generation(for: .aggregates)
        )
        XCTAssertEqual(relaunched.cursors[.aggregates], cursor)
        XCTAssertEqual(
            relaunched.retryState(for: .aggregates),
            beforeHint.retryState(for: .aggregates)
        )
    }

    func testRelaunchedHomeHintPreservesBackedOffIntermediatePipeline() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cursor = SyncMaintenanceCursor(
            observedWinningEpochID: UUID(),
            phase: 3,
            lastLogicalID: UUID(),
            offset: 512,
            payload: Data("pending-focus-fairness-progress".utf8)
        )
        var checkpoint = SyncMaintenanceCheckpoint()
        XCTAssertTrue(checkpoint.mergeSessionRepairPipeline())

        let sessions = try XCTUnwrap(checkpoint.nextRequest(now: now))
        XCTAssertEqual(sessions.kind, .sessions)
        XCTAssertTrue(checkpoint.apply(.completed(
            request: sessions,
            audit: SyncMaintenanceFetchAudit()
        ), now: now))

        let fairness = try XCTUnwrap(checkpoint.nextRequest(now: now))
        XCTAssertEqual(fairness.kind, .focusFairness)
        XCTAssertTrue(checkpoint.apply(.retry(
            request: fairness,
            cursor: cursor,
            audit: SyncMaintenanceFetchAudit(),
            category: "transient-focus-fairness-retry"
        ), now: now))

        // The backed-off higher-priority phase must not starve eligible
        // downstream work. Follow nextRequest's real priority through the end
        // of the session-derived pipeline before modelling a relaunch.
        for expectedKind: SyncMaintenanceKind in [
            .gacha, .subjects, .strata, .aggregates
        ] {
            let request = try XCTUnwrap(checkpoint.nextRequest(now: now))
            XCTAssertEqual(request.kind, expectedKind)
            XCTAssertTrue(checkpoint.apply(.completed(
                request: request,
                audit: SyncMaintenanceFetchAudit()
            ), now: now))
        }
        XCTAssertNil(checkpoint.nextRequest(now: now))
        XCTAssertEqual(checkpoint.pendingKinds, [.focusFairness])

        let persisted = try JSONEncoder().encode(checkpoint)
        var relaunched = try JSONDecoder().decode(
            SyncMaintenanceCheckpoint.self,
            from: persisted
        )
        let beforeHint = relaunched
        var gate = LocalSessionMaintenanceRequestGate()
        XCTAssertEqual(gate.consume(
            requestIsActive: true,
            firstFrameIsPresented: true,
            persistenceMode: .localOnly
        ), .sessions)

        XCTAssertFalse(relaunched.mergeSessionRepairPipeline())
        XCTAssertEqual(relaunched, beforeHint)
        XCTAssertEqual(relaunched.pendingKinds, [.focusFairness])
        XCTAssertEqual(
            relaunched.generation(for: .focusFairness),
            beforeHint.generation(for: .focusFairness)
        )
        XCTAssertEqual(relaunched.cursors[.focusFairness], cursor)
        XCTAssertEqual(
            relaunched.retryState(for: .focusFairness),
            beforeHint.retryState(for: .focusFairness)
        )
        XCTAssertNil(relaunched.nextRequest(now: now))
        let retried = try XCTUnwrap(
            relaunched.nextRequest(now: now.addingTimeInterval(1))
        )
        XCTAssertEqual(retried.kind, .focusFairness)
        XCTAssertEqual(retried.cursor, cursor)
        XCTAssertTrue(relaunched.apply(.completed(
            request: retried,
            audit: SyncMaintenanceFetchAudit()
        ), now: now.addingTimeInterval(1)))
        XCTAssertEqual(relaunched.homeSessionRepairPipelineIsActive, false)
        XCTAssertTrue(relaunched.mergeSessionRepairPipeline())
        XCTAssertEqual(
            relaunched.pendingKinds,
            SyncMaintenanceCheckpoint.sessionRepairPipelineKinds
        )
    }

    func testRelaunchedHomeHintMergesAroundUnrelatedPendingGacha() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cursor = SyncMaintenanceCursor(
            observedWinningEpochID: UUID(),
            phase: 2,
            lastLogicalID: UUID(),
            offset: 64,
            payload: Data("pending-gacha-progress".utf8)
        )
        var checkpoint = SyncMaintenanceCheckpoint()
        checkpoint.enqueue(.gacha)
        let gacha = try XCTUnwrap(checkpoint.nextRequest(now: now))
        XCTAssertEqual(gacha.kind, .gacha)
        XCTAssertTrue(checkpoint.apply(.retry(
            request: gacha,
            cursor: cursor,
            audit: SyncMaintenanceFetchAudit(),
            category: "transient-gacha-retry"
        ), now: now))

        let persisted = try JSONEncoder().encode(checkpoint)
        var relaunched = try JSONDecoder().decode(
            SyncMaintenanceCheckpoint.self,
            from: persisted
        )
        let beforeHint = relaunched

        XCTAssertTrue(relaunched.mergeSessionRepairPipeline())
        XCTAssertEqual(relaunched.homeSessionRepairPipelineIsActive, true)
        XCTAssertEqual(
            relaunched.pendingKinds,
            SyncMaintenanceCheckpoint.sessionRepairPipelineKinds
        )
        XCTAssertEqual(
            relaunched.generation(for: .gacha),
            beforeHint.generation(for: .gacha)
        )
        XCTAssertEqual(relaunched.cursors[.gacha], cursor)
        XCTAssertEqual(
            relaunched.retryState(for: .gacha),
            beforeHint.retryState(for: .gacha)
        )
        XCTAssertEqual(
            relaunched.nextRequest(now: now)?.kind,
            .sessions,
            "an unrelated pending singleton must not suppress rootless repair"
        )
    }

    func testLegacyCheckpointWithoutHomePipelineProvenanceCanMerge() throws {
        var checkpoint = SyncMaintenanceCheckpoint()
        checkpoint.enqueue(.gacha)
        let currentData = try JSONEncoder().encode(checkpoint)
        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        legacyJSON.removeValue(forKey: "homeSessionRepairPipelineIsActive")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        var restored = try JSONDecoder().decode(
            SyncMaintenanceCheckpoint.self,
            from: legacyData
        )

        XCTAssertNil(restored.homeSessionRepairPipelineIsActive)
        XCTAssertTrue(restored.mergeSessionRepairPipeline())
        XCTAssertEqual(restored.homeSessionRepairPipelineIsActive, true)
        XCTAssertEqual(
            restored.pendingKinds,
            SyncMaintenanceCheckpoint.sessionRepairPipelineKinds
        )
    }

    func testCloudHomeMaintenanceHintIsConsumedWithoutSessionEnqueue() {
        var gate = LocalSessionMaintenanceRequestGate()

        XCTAssertNil(gate.consume(
            requestIsActive: true,
            firstFrameIsPresented: true,
            persistenceMode: .cloudKit
        ))
        XCTAssertTrue(gate.hasConsumedProcessRequest)
        XCTAssertNil(gate.consume(
            requestIsActive: true,
            firstFrameIsPresented: true,
            persistenceMode: .cloudKit
        ))
    }

    func testExplicitImportWorkPrecedesDeferredVerification() throws {
        var checkpoint = SyncMaintenanceCheckpoint()
        checkpoint.enqueue(.verificationSweep)
        checkpoint.enqueue(.sessions)

        XCTAssertEqual(
            try XCTUnwrap(checkpoint.nextRequest()).kind,
            .sessions,
            "an observed import must not wait behind the idle verification marker"
        )
    }

    func testGenerationArrivalDuringSliceCannotClearNewWork() {
        var checkpoint = SyncMaintenanceCheckpoint()
        checkpoint.enqueue(.sessions)
        let request = try! XCTUnwrap(checkpoint.nextRequest())

        checkpoint.enqueue(.sessions)
        let staleResult = SyncMaintenanceSliceResult.completed(
            request: request,
            audit: SyncMaintenanceFetchAudit()
        )

        XCTAssertFalse(checkpoint.apply(staleResult))
        XCTAssertTrue(checkpoint.pendingKinds.contains(.sessions))
        XCTAssertEqual(checkpoint.generations[.sessions], request.generation + 1)
        XCTAssertNil(checkpoint.cursors[.sessions])
    }

    func testSessionDependencyExpansionIsDurableAndScoped() throws {
        var checkpoint = SyncMaintenanceCheckpoint()
        checkpoint.enqueue(.sessions)

        XCTAssertEqual(checkpoint.pendingKinds, [
            .sessions, .focusFairness, .strata, .aggregates, .gacha, .subjects
        ])

        let encoded = try JSONEncoder().encode(checkpoint)
        let restored = try JSONDecoder().decode(
            SyncMaintenanceCheckpoint.self,
            from: encoded
        )
        XCTAssertEqual(restored, checkpoint)
    }

    func testRetryBackoffIsPerKindDurableAndDoesNotStarveOtherWork() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var checkpoint = SyncMaintenanceCheckpoint()
        checkpoint.enqueue(.preferences)
        checkpoint.enqueue(.gacha)

        let preferences = try XCTUnwrap(checkpoint.nextRequest(now: now))
        XCTAssertEqual(preferences.kind, .preferences)
        XCTAssertTrue(checkpoint.apply(.retry(
            request: preferences,
            cursor: preferences.cursor,
            audit: SyncMaintenanceFetchAudit(),
            category: "oversized-preferences-group"
        ), now: now))

        XCTAssertEqual(
            checkpoint.retryState(for: .preferences)?.attempt,
            1
        )
        XCTAssertEqual(
            checkpoint.nextRequest(now: now)?.kind,
            .gacha,
            "a backed-off high-priority kind must not block independent work"
        )

        let encoded = try JSONEncoder().encode(checkpoint)
        let restored = try JSONDecoder().decode(
            SyncMaintenanceCheckpoint.self,
            from: encoded
        )
        XCTAssertEqual(restored, checkpoint)
        XCTAssertEqual(restored.nextRequest(now: now)?.kind, .gacha)
        XCTAssertEqual(
            restored.nextRequest(now: now.addingTimeInterval(1))?.kind,
            .preferences,
            "the failed kind becomes eligible again at its own deadline"
        )
    }

    func testLegacyGlobalRetryCheckpointMigratesWithoutGlobalStarvation() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var checkpoint = SyncMaintenanceCheckpoint()
        checkpoint.enqueue(.preferences)
        checkpoint.enqueue(.gacha)
        let preferences = try XCTUnwrap(checkpoint.nextRequest(now: now))
        XCTAssertTrue(checkpoint.apply(.retry(
            request: preferences,
            cursor: nil,
            audit: SyncMaintenanceFetchAudit(),
            category: "legacy-failure"
        ), now: now))

        let currentData = try JSONEncoder().encode(checkpoint)
        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        legacyJSON.removeValue(forKey: "retryStates")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
        let restored = try JSONDecoder().decode(
            SyncMaintenanceCheckpoint.self,
            from: legacyData
        )

        XCTAssertEqual(restored.retryState(for: .preferences)?.attempt, 1)
        XCTAssertEqual(restored.nextRequest(now: now)?.kind, .gacha)
    }

    func testPreferencesSliceIsReadOnlyAndDoesNotReadHistoricalModels() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let day = FairnessPolicy.deviceDayKey(for: .now)
        context.insert(Prefs(
            id: BoundedLaunchPreparation.canonicalPrefsID,
            manualDayKey: day,
            manualUsedToday: 1,
            soundOn: true,
            activityEpochID: nil,
            settingsWriterID: "device-a"
        ))
        context.insert(Prefs(
            id: UUID(),
            manualDayKey: day,
            manualUsedToday: 2,
            soundOn: false,
            reminderEnabled: true,
            activityEpochID: nil,
            settingsWriterID: "device-a"
        ))
        let unknownEpochID = UUID()
        context.insert(Prefs(
            id: UUID(),
            soundOn: true,
            activityEpochID: unknownEpochID
        ))
        for index in 0 ..< 300 {
            context.insert(makeSession(
                id: UUID(),
                grams: index + 1,
                epochID: nil
            ))
        }
        try context.save()

        let request = SyncMaintenanceSliceRequest(
            kind: .preferences,
            generation: 1,
            cursor: nil,
            limits: .production
        )
        let result = try await SyncMaintenanceSliceWorker(
            modelContainer: container
        ).run(request)

        XCTAssertEqual(result.disposition, .completed)
        XCTAssertEqual(result.audit.maximumRowsReturnedByAnyFetch, 3)
        XCTAssertEqual(result.audit.totalRowsAccessed, 3)
        XCTAssertEqual(result.audit.saveCount, 0)
        let prefs = try context.fetch(FetchDescriptor<Prefs>())
        XCTAssertEqual(
            prefs.count,
            3,
            "maintenance retains every source replica, including unknown epochs"
        )
        let canonical = try XCTUnwrap(prefs.first {
            $0.activityEpochID == nil
                && $0.id == BoundedLaunchPreparation.canonicalPrefsID
        })
        XCTAssertEqual(canonical.manualUsedToday, 1)
        XCTAssertTrue(canonical.soundOn)
        XCTAssertFalse(canonical.reminderEnabled)
        let resolved = try PrefsSyncPolicy.resolvedState(
            in: prefs,
            currentEpochID: nil,
            writerID: "device-a",
            currentDay: day
        )
        XCTAssertEqual(resolved.manualUsedToday, 2)
        XCTAssertFalse(resolved.soundOn)
        XCTAssertFalse(
            resolved.reminderEnabled,
            "an unstamped legacy privacy tie fails closed"
        )
        XCTAssertNotNil(prefs.first { $0.activityEpochID == unknownEpochID })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StudySession>()), 300)
    }

    func testManualQuotaKeepsOtherDeviceAvailableAfterOfflineCountersArrive() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day = FairnessPolicy.deviceDayKey(for: now)
        let deviceA = Prefs(manualDayKey: day, manualUsedToday: 3,
            settingsWriterID: "device-a")
        let deviceB = Prefs(manualDayKey: day, manualUsedToday: 0,
            settingsWriterID: "device-b")
        context.insert(deviceA)
        context.insert(deviceB)
        try context.save()

        for rows in [[deviceA, deviceB], [deviceB, deviceA]] {
            let a = try PrefsSyncPolicy.resolvedState(in: rows, currentEpochID: nil,
                writerID: "device-a", currentDay: day)
            let b = try PrefsSyncPolicy.resolvedState(in: rows, currentEpochID: nil,
                writerID: "device-b", currentDay: day)
            XCTAssertEqual(a.manualUsedToday, 3)
            XCTAssertFalse(FairnessPolicy.consumeManualEntry(
                state: ManualCounterState(dayKey: day, usedToday: a.manualUsedToday), at: now).isAllowed)
            XCTAssertEqual(b.manualUsedToday, 0)
            XCTAssertTrue(FairnessPolicy.consumeManualEntry(
                state: ManualCounterState(dayKey: day, usedToday: b.manualUsedToday), at: now).isAllowed)
        }

        let b = try PrefsSyncPolicy.resolvedState(in: [deviceA, deviceB], currentEpochID: nil,
            writerID: "device-b", currentDay: day)
        let decision = FairnessPolicy.consumeManualEntry(
            state: ManualCounterState(dayKey: day, usedToday: b.manualUsedToday), at: now)
        let writer = try PrefsSyncPolicy.ensureWriterRow(context: context,
            writerID: "device-b", currentEpochID: nil)
        writer.manualDayKey = decision.state.dayKey
        writer.manualUsedToday = decision.state.usedToday
        try context.save()

        let reader = ModelContext(container)
        reader.autosaveEnabled = false
        let reopened = try PrefsSyncPolicy.fetchBounded(from: reader)
        XCTAssertEqual(reopened.count, 2)
        XCTAssertEqual(try PrefsSyncPolicy.resolvedState(in: reopened, currentEpochID: nil,
            writerID: "device-a", currentDay: day).manualUsedToday, 3)
        XCTAssertEqual(try PrefsSyncPolicy.resolvedState(in: reopened, currentEpochID: nil,
            writerID: "device-b", currentDay: day).manualUsedToday, 1)
    }

    func testPreferenceEditDoesNotCopyAnotherDevicesManualQuota() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let day = "2027-01-15"
        let deviceA = Prefs(manualDayKey: day, manualUsedToday: 3,
            settingsWriterID: "device-a")
        let deviceB = Prefs(manualDayKey: day, manualUsedToday: 1,
            settingsWriterID: "device-b")
        context.insert(deviceA)
        context.insert(deviceB)
        try context.save()
        let foreignBefore = prefsFingerprint(deviceA)

        let writer = try PrefsSyncPolicy.mutate(.sound, context: context,
            writerID: "device-b", currentEpochID: nil, currentDay: day) {
                $0.soundOn = false
            }
        try context.save()
        XCTAssertTrue(writer === deviceB)
        XCTAssertEqual(writer.manualUsedToday, 1)
        XCTAssertEqual(deviceA.manualUsedToday, 3)
        XCTAssertEqual(prefsFingerprint(deviceA), foreignBefore)
        let reader = ModelContext(container)
        reader.autosaveEnabled = false
        let reopened = try PrefsSyncPolicy.fetchBounded(from: reader)
        XCTAssertEqual(try PrefsSyncPolicy.resolvedState(in: reopened, currentEpochID: nil,
            writerID: "device-b", currentDay: day).manualUsedToday, 1)
        XCTAssertFalse(try PrefsSyncPolicy.resolvedState(in: reopened, currentEpochID: nil,
            writerID: "device-a", currentDay: day).soundOn,
            "The shared setting still converges independently of the per-device quota")
    }

    func testUnattributedLegacyQuotaIsRetainedWithoutClaimingTheNewDevice() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let day = "2027-01-15"
        let legacy = Prefs(manualDayKey: day, manualUsedToday: 3,
            hasCompletedOnboarding: true)
        let foreign = Prefs(manualDayKey: day, manualUsedToday: 2,
            settingsWriterID: "device-a")
        context.insert(legacy)
        context.insert(foreign)
        try context.save()

        XCTAssertEqual(try PrefsSyncPolicy.resolvedState(in: [legacy, foreign], currentEpochID: nil,
            writerID: "device-b", currentDay: day).manualUsedToday, 0)
        let writer = try PrefsSyncPolicy.mutate(.keepScreenAwake, context: context,
            writerID: "device-b", currentEpochID: nil, currentDay: day) {
                $0.keepScreenAwake = false
            }
        try context.save()
        XCTAssertEqual(writer.settingsWriterID, "device-b")
        XCTAssertEqual(writer.manualUsedToday, 0)
        XCTAssertTrue(writer.hasCompletedOnboarding)
        XCTAssertEqual(legacy.settingsWriterID, "")
        XCTAssertEqual(legacy.manualUsedToday, 3)
        XCTAssertEqual(foreign.manualUsedToday, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Prefs>()), 3)
        XCTAssertEqual(try PrefsSyncPolicy.resolvedState(in: [legacy], currentEpochID: nil,
            writerID: "", currentDay: day).manualUsedToday, 0)
    }

    func testOwnedQuotaDuplicatesUseMaximumOnlyWithinCurrentDayAndEpoch() throws {
        let day = "2027-01-15"
        let epoch = UUID()
        let rows = [
            Prefs(manualDayKey: day, manualUsedToday: 1, activityEpochID: epoch,
                settingsWriterID: "device-b"),
            Prefs(manualDayKey: day, manualUsedToday: 2, activityEpochID: epoch,
                settingsWriterID: "device-b"),
            Prefs(manualDayKey: "2027-01-14", manualUsedToday: 3, activityEpochID: epoch,
                settingsWriterID: "device-b"),
            Prefs(manualDayKey: day, manualUsedToday: 3,
                settingsWriterID: "device-b"),
            Prefs(manualDayKey: day, manualUsedToday: 3, activityEpochID: epoch,
                settingsWriterID: "device-a")
        ]
        for values in [rows, Array(rows.reversed())] {
            XCTAssertEqual(try PrefsSyncPolicy.resolvedState(in: values, currentEpochID: epoch,
                writerID: "device-b", currentDay: day).manualUsedToday, 2)
            XCTAssertEqual(try PrefsSyncPolicy.resolvedState(in: values, currentEpochID: epoch,
                writerID: "device-b", currentDay: "2027-01-16").manualUsedToday, 0)
            XCTAssertEqual(try PrefsSyncPolicy.resolvedState(in: values, currentEpochID: UUID(),
                writerID: "device-b", currentDay: day).manualUsedToday, 0)
        }
    }

    func testSessionDuplicateAtPageBoundaryIsResolvedWithoutSourceMutation() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        for index in 1 ... 127 {
            context.insert(makeSession(
                id: orderedUUID(index),
                grams: index,
                epochID: nil
            ))
        }
        let duplicateID = orderedUUID(128)
        context.insert(makeSession(
            id: duplicateID,
            grams: 100,
            kind: .gold,
            epochID: nil
        ))
        context.insert(makeSession(
            id: duplicateID,
            grams: 220,
            kind: .prism,
            epochID: nil
        ))
        try context.save()

        let initialRows = try context.fetch(FetchDescriptor<StudySession>())
        let initialFingerprint = initialRows.map(sessionFingerprint).sorted()
        let firstRequest = SyncMaintenanceSliceRequest(
            kind: .sessions,
            generation: 7,
            cursor: nil,
            limits: .production
        )
        let first = try await SyncMaintenanceSliceWorker(
            modelContainer: container
        ).run(firstRequest)
        XCTAssertEqual(first.disposition, .moreWork)
        XCTAssertEqual(first.audit.saveCount, 0)

        // A process can crash after returning a cursor but before persisting it.
        // Replaying the same read-only source slice must be byte-for-byte stable.
        let replay = try await SyncMaintenanceSliceWorker(
            modelContainer: container
        ).run(firstRequest)
        XCTAssertEqual(replay.nextCursor, first.nextCursor)
        XCTAssertEqual(replay.audit.saveCount, 0)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<StudySession>())
                .map(sessionFingerprint).sorted(),
            initialFingerprint
        )

        var cursor = replay.nextCursor
        var completed = false
        for _ in 0 ..< 4 {
            let request = SyncMaintenanceSliceRequest(
                kind: .sessions,
                generation: 7,
                cursor: cursor,
                limits: .production
            )
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(request)
            assertBudget(result.audit)
            XCTAssertNotEqual(result.disposition, .retry)
            XCTAssertEqual(result.audit.saveCount, 0)
            cursor = result.nextCursor
            if result.disposition == .completed {
                completed = true
                break
            }
        }

        XCTAssertTrue(completed)
        let sessions = try context.fetch(FetchDescriptor<StudySession>())
        XCTAssertEqual(sessions.count, 129)
        XCTAssertEqual(sessions.map(sessionFingerprint).sorted(), initialFingerprint)
        let copies = sessions.filter { $0.id == duplicateID }
        XCTAssertEqual(copies.count, 2)
        let resolved = try XCTUnwrap(
            StudySessionSyncPolicy.canonicalSession(from: copies)
        )
        XCTAssertEqual(resolved.grams, 220)
        XCTAssertEqual(resolved.pebbleKind, .prism)
        XCTAssertEqual(resolved.source, .timer)
        XCTAssertTrue(
            StudySessionSyncPolicy.canonicalSession(from: Array(copies.reversed()))
                === resolved
        )
    }

    func testSessionMaintenancePreservesAndIgnoresUnsupportedRows() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let sharedID = orderedUUID(500)
        let valid = makeSession(id: sharedID, grams: 250, epochID: nil)
        let hostileDuplicate = makeSession(id: sharedID, grams: 250, epochID: nil)
        hostileDuplicate.seconds = Int.max
        hostileDuplicate.grams = Int.max
        let reversed = makeSession(id: orderedUUID(501), grams: 250, epochID: nil)
        reversed.startAt = reversed.endAt.addingTimeInterval(1)
        [valid, hostileDuplicate, reversed].forEach(context.insert)
        try context.save()

        var cursor: SyncMaintenanceCursor?
        for _ in 0..<4 {
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(SyncMaintenanceSliceRequest(
                kind: .sessions,
                generation: 70,
                cursor: cursor,
                limits: .production
            ))
            XCTAssertNotEqual(result.disposition, .retry)
            if result.disposition == .completed { break }
            cursor = result.nextCursor
        }

        let rows = try context.fetch(FetchDescriptor<StudySession>())
        XCTAssertEqual(rows.count, 3, "quarantine is non-destructive")
        XCTAssertEqual(rows.filter { $0.id == sharedID }.count, 2)
        XCTAssertTrue(rows.contains {
            $0.id == sharedID && $0.seconds == Int.max && $0.grams == Int.max
        })
        XCTAssertTrue(rows.contains {
            $0.id == reversed.id && $0.startAt > $0.endAt
        })
        XCTAssertEqual(
            StudySessionIntegrityPolicy.supported(rows).map(\.id),
            [valid.id]
        )
    }

    func testStudySessionResolverIsOrderIndependentAcrossPartialDelivery() throws {
        let logicalID = orderedUUID(600)
        let a = makeSession(id: logicalID, grams: 100, epochID: nil)
        a.syncRecordID = orderedUUID(601)
        let b = makeSession(id: logicalID, grams: 220, kind: .prism, epochID: nil)
        b.syncRecordID = orderedUUID(602)
        let c = makeSession(id: logicalID, grams: 220, kind: .prism, epochID: nil)
        c.syncRecordID = orderedUUID(603)
        c.source = .timerDemoted

        XCTAssertTrue(StudySessionSyncPolicy.canonicalSession(from: [a, b]) === b)
        XCTAssertTrue(StudySessionSyncPolicy.canonicalSession(from: [b, a]) === b)
        XCTAssertTrue(StudySessionSyncPolicy.canonicalSession(from: [b, c]) === c)
        XCTAssertTrue(StudySessionSyncPolicy.canonicalSession(from: [c, b]) === c)
        XCTAssertTrue(StudySessionSyncPolicy.canonicalSession(from: [a, b, c]) === c)
        XCTAssertTrue(StudySessionSyncPolicy.canonicalSession(from: [c, b, a]) === c)
        XCTAssertEqual(
            StudySessionSyncPolicy.canonicalSessions(from: [a, b, c]).count,
            1,
            "all accounting boundaries count one logical completion"
        )

        // The late third copy remains untouched and can change the read oracle;
        // a destructive A/B fold would have erased that evidence.
        XCTAssertEqual(a.grams, 100)
        XCTAssertEqual(b.grams, 220)
        XCTAssertEqual(c.source, .timerDemoted)
    }

    func testEqualStudySessionCopiesUseStablePhysicalTotalOrder() throws {
        let logicalID = orderedUUID(610)
        let low = makeSession(id: logicalID, grams: 250, epochID: nil)
        low.syncRecordID = orderedUUID(611)
        let high = makeSession(id: logicalID, grams: 250, epochID: nil)
        high.syncRecordID = orderedUUID(612)

        XCTAssertTrue(StudySessionSyncPolicy.canonicalSession(from: [low, high]) === high)
        XCTAssertTrue(StudySessionSyncPolicy.canonicalSession(from: [high, low]) === high)
    }

    func testSubjectDeletionIsStickyAcrossHigherOfflineRenameAndPartialDelivery() throws {
        let logicalID = orderedUUID(620)
        let older = Subject(
            id: logicalID,
            name: "元のテーマ",
            colorHex: Constants.Color.english,
            sortOrder: 0,
            syncRecordID: orderedUUID(621),
            contentRevision: 4,
            contentMutationID: orderedUUID(631)
        )
        let tombstone = Subject(
            id: logicalID,
            name: "削除済み",
            colorHex: Constants.Color.english,
            sortOrder: 0,
            deletedAt: Date(timeIntervalSince1970: 100),
            syncRecordID: orderedUUID(622),
            contentRevision: 5,
            contentMutationID: orderedUUID(632)
        )
        let laterOfflineRename = Subject(
            id: logicalID,
            name: "オフラインで二度変更",
            colorHex: Constants.Color.mathematics,
            sortOrder: 0,
            syncRecordID: orderedUUID(623),
            contentRevision: 6,
            contentMutationID: orderedUUID(633)
        )

        for values in [
            [older, tombstone],
            [tombstone, older],
            [tombstone, laterOfflineRename],
            [laterOfflineRename, tombstone],
            [older, tombstone, laterOfflineRename],
            [laterOfflineRename, tombstone, older]
        ] {
            XCTAssertTrue(SubjectSyncPolicy.canonical(from: values) === tombstone)
            XCTAssertTrue(SubjectSyncPolicy.presentationSubjects(from: values).isEmpty)
        }

        let legacyTombstone = Subject(
            id: logicalID,
            name: "移行前に削除",
            colorHex: Constants.Color.english,
            sortOrder: 0,
            deletedAt: Date(timeIntervalSince1970: 90),
            syncRecordID: orderedUUID(624),
            contentRevision: 0
        )
        XCTAssertTrue(
            SubjectSyncPolicy.canonical(from: [laterOfflineRename, legacyTombstone])
                === legacyTombstone
        )
    }

    func testSubjectMutationChangesOnlySelectedPhysicalRow() throws {
        let logicalID = orderedUUID(640)
        let selected = Subject(
            id: logicalID,
            name: "selected",
            colorHex: Constants.Color.english,
            sortOrder: 0,
            syncRecordID: orderedUUID(641),
            contentRevision: 2,
            contentMutationID: orderedUUID(651)
        )
        let foreign = Subject(
            id: logicalID,
            name: "foreign",
            colorHex: Constants.Color.mathematics,
            sortOrder: 0,
            syncRecordID: orderedUUID(642),
            contentRevision: 4,
            contentMutationID: orderedUUID(652)
        )
        let foreignFingerprint = subjectFingerprint(foreign)
        selected.name = "explicit edit"
        try SubjectSyncPolicy.recordUserMutation(
            from: selected,
            among: [selected, foreign],
            mutationID: orderedUUID(653)
        )

        XCTAssertEqual(selected.contentRevision, 5)
        XCTAssertEqual(selected.contentMutationID, orderedUUID(653))
        XCTAssertEqual(subjectFingerprint(foreign), foreignFingerprint)
    }

    func testSubjectMutationRejectsReplicaCatalogueOverflow() {
        let logicalID = UUID()
        let source = Subject(
            id: logicalID,
            name: "編集前",
            colorHex: "#123456",
            sortOrder: 0
        )
        let values = [source] + (0..<SubjectSyncPolicy.maximumPhysicalRows).map { index in
            Subject(
                id: UUID(),
                name: "別カテゴリ\(index)",
                colorHex: "#654321",
                sortOrder: index + 1
            )
        }

        XCTAssertThrowsError(
            try SubjectSyncPolicy.recordUserMutation(
                from: source,
                among: values
            )
        ) { error in
            XCTAssertEqual(
                error as? SubjectSyncPolicy.MutationError,
                .tooManyPhysicalRows
            )
        }
        XCTAssertEqual(source.contentRevision, 1)
    }

    func testAchievementMaintenanceRetainsPartialReplicasAndLateRestoreEvidence() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let logicalID = orderedUUID(655)
        let deleteToken = orderedUUID(656)
        let tombstone = AchievementStone(
            id: logicalID,
            kind: .examPass,
            note: "deleted",
            achievedAt: Date(timeIntervalSince1970: 100),
            createdAt: Date(timeIntervalSince1970: 100),
            revision: 5,
            deletedAt: Date(timeIntervalSince1970: 110),
            deletionMutationID: deleteToken,
            deletionRevision: 5,
            updatedAt: Date(timeIntervalSince1970: 110),
            syncRecordID: orderedUUID(657)
        )
        let unseenOfflineEdit = AchievementStone(
            id: logicalID,
            kind: .workMilestone,
            note: "unseen edit",
            achievedAt: Date(timeIntervalSince1970: 100),
            createdAt: Date(timeIntervalSince1970: 100),
            revision: 6,
            updatedAt: Date(timeIntervalSince1970: 120),
            syncRecordID: orderedUUID(658)
        )
        [tombstone, unseenOfflineEdit].forEach(context.insert)
        try context.save()
        let before = [tombstone, unseenOfflineEdit].map(achievementFingerprint).sorted()

        var cursor: SyncMaintenanceCursor?
        for _ in 0..<4 {
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(SyncMaintenanceSliceRequest(
                kind: .achievements,
                generation: 81,
                cursor: cursor,
                limits: .production
            ))
            XCTAssertEqual(result.audit.saveCount, 0)
            if result.disposition == .completed { break }
            cursor = result.nextCursor
        }
        var rows = try context.fetch(FetchDescriptor<AchievementStone>())
        XCTAssertEqual(rows.map(achievementFingerprint).sorted(), before)
        XCTAssertTrue(
            AchievementStonePolicy.canonicalStone(from: rows) === tombstone
        )

        let explicitRestore = AchievementStone(
            id: logicalID,
            kind: .examPass,
            note: "restored",
            achievedAt: Date(timeIntervalSince1970: 100),
            createdAt: Date(timeIntervalSince1970: 100),
            revision: 7,
            deletionMutationID: deleteToken,
            deletionRevision: 5,
            restoredDeletionMutationID: deleteToken,
            updatedAt: Date(timeIntervalSince1970: 130),
            syncRecordID: orderedUUID(659)
        )
        context.insert(explicitRestore)
        try context.save()
        let afterLateArrival = (rows + [explicitRestore])
            .map(achievementFingerprint)
            .sorted()
        cursor = nil
        for _ in 0..<4 {
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(SyncMaintenanceSliceRequest(
                kind: .achievements,
                generation: 82,
                cursor: cursor,
                limits: .production
            ))
            XCTAssertEqual(result.audit.saveCount, 0)
            if result.disposition == .completed { break }
            cursor = result.nextCursor
        }
        rows = try context.fetch(FetchDescriptor<AchievementStone>())
        XCTAssertEqual(rows.map(achievementFingerprint).sorted(), afterLateArrival)
        XCTAssertTrue(
            AchievementStonePolicy.canonicalStone(from: rows) === explicitRestore
        )
    }

    func testPreferenceGroupsPreserveIndependentOfflineChangesAndReversals() throws {
        let soundDevice = Prefs(soundOn: false, hapticsOn: true)
        soundDevice.syncRecordID = orderedUUID(660)
        soundDevice.soundRevision = 1
        soundDevice.soundMutationID = orderedUUID(670)
        let hapticsDevice = Prefs(soundOn: true, hapticsOn: false)
        hapticsDevice.syncRecordID = orderedUUID(661)
        hapticsDevice.hapticsRevision = 1
        hapticsDevice.hapticsMutationID = orderedUUID(671)
        let lateLegacy = Prefs(soundOn: true, hapticsOn: true)
        lateLegacy.syncRecordID = orderedUUID(662)

        let concurrent = try PrefsSyncPolicy.resolvedState(
            in: [soundDevice, hapticsDevice, lateLegacy],
            currentEpochID: nil
        )
        let reversed = try PrefsSyncPolicy.resolvedState(
            in: [lateLegacy, hapticsDevice, soundDevice],
            currentEpochID: nil
        )
        XCTAssertFalse(concurrent.soundOn)
        XCTAssertFalse(concurrent.hapticsOn)
        XCTAssertEqual(concurrent, reversed)

        let laterIntent = Prefs(soundOn: true, reminderEnabled: false)
        laterIntent.syncRecordID = orderedUUID(663)
        laterIntent.soundRevision = 2
        laterIntent.soundMutationID = orderedUUID(672)
        laterIntent.reminderEnabledRevision = 2
        laterIntent.reminderEnabledMutationID = orderedUUID(673)
        let olderIntent = Prefs(soundOn: false, reminderEnabled: true)
        olderIntent.syncRecordID = orderedUUID(664)
        olderIntent.soundRevision = 1
        olderIntent.soundMutationID = orderedUUID(674)
        olderIntent.reminderEnabledRevision = 1
        olderIntent.reminderEnabledMutationID = orderedUUID(675)
        let lateStale = Prefs(soundOn: false, reminderEnabled: true)
        lateStale.syncRecordID = orderedUUID(665)

        let reversible = try PrefsSyncPolicy.resolvedState(
            in: [laterIntent, olderIntent, lateStale],
            currentEpochID: nil
        )
        XCTAssertTrue(reversible.soundOn, "higher revision permits false to true")
        XCTAssertFalse(
            reversible.reminderEnabled,
            "higher revision permits true to false despite a late legacy copy"
        )
    }

    func testSixHourPreferenceConvergesWhileOverLimitReplicaIsIgnored() throws {
        let earlier = Prefs(preferredFocusMinutes: 180)
        earlier.preferredFocusMinutesRevision = 1
        earlier.preferredFocusMinutesMutationID = UUID()
        let latest = Prefs(preferredFocusMinutes: 360)
        latest.preferredFocusMinutesRevision = 2
        latest.preferredFocusMinutesMutationID = UUID()
        let invalidNewer = Prefs(preferredFocusMinutes: 361)
        invalidNewer.preferredFocusMinutesRevision = 3
        invalidNewer.preferredFocusMinutesMutationID = UUID()

        let forward = try PrefsSyncPolicy.resolvedState(
            in: [earlier, invalidNewer, latest], currentEpochID: nil
        )
        let reversed = try PrefsSyncPolicy.resolvedState(
            in: [latest, invalidNewer, earlier], currentEpochID: nil
        )
        XCTAssertEqual(forward.preferredFocusMinutes, 360)
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(try PrefsSyncPolicy.resolvedState(
            in: [invalidNewer], currentEpochID: nil
        ).preferredFocusMinutes, 25)
        XCTAssertEqual(invalidNewer.preferredFocusMinutes, 361,
                       "An unsupported replica must be ignored without rewriting its stored value")
    }

    func testTimerDisplayModeConvergesAndInvalidValuesFallBackSafely() throws {
        let earlier = Prefs(
            timerDisplayModeRawValue: TimerDisplayMode.timeOnly.rawValue
        )
        earlier.syncRecordID = orderedUUID(745)
        earlier.timerDisplayModeRevision = 2
        earlier.timerDisplayModeMutationID = orderedUUID(746)

        let latest = Prefs(
            timerDisplayModeRawValue: TimerDisplayMode.filledDial.rawValue
        )
        latest.syncRecordID = orderedUUID(747)
        latest.timerDisplayModeRevision = 3
        latest.timerDisplayModeMutationID = orderedUUID(748)

        let invalidNewer = Prefs()
        invalidNewer.syncRecordID = orderedUUID(749)
        invalidNewer.timerDisplayModeRawValue = "not-a-timer-display-mode"
        invalidNewer.timerDisplayModeRevision = 4
        invalidNewer.timerDisplayModeMutationID = orderedUUID(750)

        let forward = try PrefsSyncPolicy.resolvedState(
            in: [earlier, invalidNewer, latest],
            currentEpochID: nil
        )
        let reversed = try PrefsSyncPolicy.resolvedState(
            in: [latest, invalidNewer, earlier],
            currentEpochID: nil
        )
        XCTAssertEqual(forward.timerDisplayMode, .filledDial)
        XCTAssertEqual(reversed.timerDisplayMode, .filledDial)
        XCTAssertEqual(forward, reversed)

        let allInvalid = try PrefsSyncPolicy.resolvedState(
            in: [invalidNewer],
            currentEpochID: nil
        )
        XCTAssertEqual(allInvalid.timerDisplayMode, .ringAndTime)
        XCTAssertEqual(
            TimerDisplayMode.resolved("not-a-timer-display-mode"),
            .ringAndTime
        )
    }

    func testSensoryPreferenceResolutionIsolatesSoundAndHapticsFailures() {
        let sharedSoundStamp = orderedUUID(676)
        let soundA = Prefs(soundOn: true, hapticsOn: true)
        soundA.syncRecordID = orderedUUID(677)
        soundA.soundRevision = 4
        soundA.soundMutationID = sharedSoundStamp
        soundA.hapticsRevision = 2
        soundA.hapticsMutationID = orderedUUID(678)

        let soundB = Prefs(soundOn: false, hapticsOn: true)
        soundB.syncRecordID = orderedUUID(679)
        soundB.soundRevision = 4
        soundB.soundMutationID = sharedSoundStamp

        XCTAssertEqual(
            PrefsSyncPolicy.resolvedSensoryState(in: [soundA, soundB]),
            PrefsSyncPolicy.ResolvedSensoryState(
                soundOn: false,
                hapticsOn: true
            )
        )

        let sharedHapticsStamp = orderedUUID(674)
        let hapticsA = Prefs(soundOn: true, hapticsOn: true)
        hapticsA.syncRecordID = orderedUUID(673)
        hapticsA.soundRevision = 2
        hapticsA.soundMutationID = orderedUUID(672)
        hapticsA.hapticsRevision = 5
        hapticsA.hapticsMutationID = sharedHapticsStamp

        let hapticsB = Prefs(soundOn: true, hapticsOn: false)
        hapticsB.syncRecordID = orderedUUID(671)
        hapticsB.hapticsRevision = 5
        hapticsB.hapticsMutationID = sharedHapticsStamp

        XCTAssertEqual(
            PrefsSyncPolicy.resolvedSensoryState(in: [hapticsA, hapticsB]),
            PrefsSyncPolicy.ResolvedSensoryState(
                soundOn: true,
                hapticsOn: false
            )
        )

        let invalidSound = Prefs(soundOn: true, hapticsOn: true)
        invalidSound.soundRevision = 1
        invalidSound.soundMutationID = nil
        XCTAssertEqual(
            PrefsSyncPolicy.resolvedSensoryState(in: [invalidSound]),
            PrefsSyncPolicy.ResolvedSensoryState(
                soundOn: false,
                hapticsOn: true
            )
        )

        XCTAssertEqual(
            PrefsSyncPolicy.resolvedSensoryState(in: []),
            PrefsSyncPolicy.ResolvedSensoryState(
                soundOn: true,
                hapticsOn: true
            )
        )

        for soundOn in [false, true] {
            for hapticsOn in [false, true] {
                XCTAssertEqual(
                    PrefsSyncPolicy.resolvedSensoryState(
                        in: [Prefs(soundOn: soundOn, hapticsOn: hapticsOn)]
                    ),
                    PrefsSyncPolicy.ResolvedSensoryState(
                        soundOn: soundOn,
                        hapticsOn: hapticsOn
                    )
                )
            }
        }

        let overflow = (0...PrefsSyncPolicy.maximumPhysicalRows).map { _ in Prefs() }
        XCTAssertEqual(
            PrefsSyncPolicy.resolvedSensoryState(in: overflow),
            PrefsSyncPolicy.ResolvedSensoryState(
                soundOn: false,
                hapticsOn: false
            )
        )
    }

    func testTimerCompletionChoicesResolveIndependentlyAndFailOnlyTheirGroup() {
        let soundChoice = Prefs(
            timerCompletionSoundRawValue: TimerCompletionSound.bright.rawValue
        )
        soundChoice.syncRecordID = orderedUUID(735)
        soundChoice.timerCompletionSoundRevision = 2
        soundChoice.timerCompletionSoundMutationID = orderedUUID(736)

        let hapticChoice = Prefs(
            timerCompletionHapticRawValue: TimerCompletionHaptic.strong.rawValue
        )
        hapticChoice.syncRecordID = orderedUUID(737)
        hapticChoice.timerCompletionHapticRevision = 3
        hapticChoice.timerCompletionHapticMutationID = orderedUUID(738)

        let resolved = PrefsSyncPolicy.resolvedSensoryState(
            in: [hapticChoice, soundChoice]
        )
        XCTAssertEqual(resolved.timerCompletionSound, .bright)
        XCTAssertEqual(resolved.timerCompletionHaptic, .strong)

        let invalidSound = Prefs()
        invalidSound.timerCompletionSoundRawValue = "not-a-sound"
        invalidSound.timerCompletionSoundRevision = 4
        invalidSound.timerCompletionSoundMutationID = orderedUUID(739)
        let allInvalidSound = PrefsSyncPolicy.resolvedSensoryState(
            in: [invalidSound, hapticChoice]
        )
        XCTAssertEqual(allInvalidSound.timerCompletionSound, .standard)
        XCTAssertEqual(allInvalidSound.timerCompletionHaptic, .strong)

        let conflictingA = Prefs(
            timerCompletionSoundRawValue: TimerCompletionSound.soft.rawValue
        )
        conflictingA.timerCompletionSoundRevision = 5
        conflictingA.timerCompletionSoundMutationID = orderedUUID(740)
        let conflictingB = Prefs(
            timerCompletionSoundRawValue: TimerCompletionSound.bright.rawValue
        )
        conflictingB.timerCompletionSoundRevision = 5
        conflictingB.timerCompletionSoundMutationID = orderedUUID(740)
        let conflictedSound = PrefsSyncPolicy.resolvedSensoryState(
            in: [conflictingA, conflictingB, hapticChoice]
        )
        XCTAssertEqual(conflictedSound.timerCompletionSound, .standard)
        XCTAssertEqual(conflictedSound.timerCompletionHaptic, .strong)
    }

    func testPreferenceMaintenanceAuditsTimerCompletionStampConflicts() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let sharedMutationID = orderedUUID(742)
        let soft = Prefs(
            id: orderedUUID(743),
            timerCompletionSoundRawValue: TimerCompletionSound.soft.rawValue
        )
        soft.timerCompletionSoundRevision = 7
        soft.timerCompletionSoundMutationID = sharedMutationID
        let bright = Prefs(
            id: orderedUUID(744),
            timerCompletionSoundRawValue: TimerCompletionSound.bright.rawValue
        )
        bright.timerCompletionSoundRevision = 7
        bright.timerCompletionSoundMutationID = sharedMutationID
        context.insert(soft)
        context.insert(bright)
        try context.save()

        let result = try await SyncMaintenanceSliceWorker(
            modelContainer: container
        ).run(SyncMaintenanceSliceRequest(
            kind: .preferences,
            generation: 1,
            cursor: nil,
            limits: .production
        ))

        XCTAssertEqual(result.disposition, .retry)
        XCTAssertEqual(
            result.failureCategory,
            "conflicting-preference-stamp"
        )
        XCTAssertEqual(result.audit.saveCount, 0)
    }

    func testForegroundCompletionFeedbackAvoidsRecoveredAndNotificationDuplicates() {
        XCTAssertTrue(TimerCompletionForegroundFeedbackPolicy.shouldPlay(
            recoveredAfterExpiration: false,
            returnedFromBackground: false,
            notificationMayHaveDelivered: false
        ))
        XCTAssertTrue(TimerCompletionForegroundFeedbackPolicy.shouldPlay(
            recoveredAfterExpiration: false,
            returnedFromBackground: true,
            notificationMayHaveDelivered: false
        ))
        XCTAssertFalse(TimerCompletionForegroundFeedbackPolicy.shouldPlay(
            recoveredAfterExpiration: false,
            returnedFromBackground: true,
            notificationMayHaveDelivered: true
        ))
        XCTAssertTrue(TimerCompletionForegroundFeedbackPolicy.shouldPlay(
            recoveredAfterExpiration: true,
            returnedFromBackground: false,
            notificationMayHaveDelivered: false
        ))
        XCTAssertFalse(TimerCompletionForegroundFeedbackPolicy.shouldPlay(
            recoveredAfterExpiration: true,
            returnedFromBackground: false,
            notificationMayHaveDelivered: true
        ))
    }

    func testForegroundCompletionFeedbackTrustsWitnessOnlyWithAlignedClocks() {
        let anchorDate = Date(timeIntervalSinceReferenceDate: 10_000)
        let anchor = ClockAnchor(
            wallDate: anchorDate,
            systemUptime: 1_000
        )

        XCTAssertTrue(
            TimerCompletionForegroundFeedbackPolicy
                .notificationTimingIsTrustworthy(
                    source: .timer,
                    clockAnchor: anchor,
                    now: anchorDate.addingTimeInterval(60),
                    uptime: 1_060
                )
        )
        XCTAssertFalse(
            TimerCompletionForegroundFeedbackPolicy
                .notificationTimingIsTrustworthy(
                    source: .timer,
                    clockAnchor: anchor,
                    now: anchorDate.addingTimeInterval(62),
                    uptime: 1_060
                )
        )
        XCTAssertFalse(
            TimerCompletionForegroundFeedbackPolicy
                .notificationTimingIsTrustworthy(
                    source: .timerDemoted,
                    clockAnchor: anchor,
                    now: anchorDate.addingTimeInterval(60),
                    uptime: 1_060
                )
        )
        XCTAssertFalse(
            TimerCompletionForegroundFeedbackPolicy
                .notificationTimingIsTrustworthy(
                    source: .timer,
                    clockAnchor: nil,
                    now: anchorDate.addingTimeInterval(60),
                    uptime: 1_060
                )
        )
    }

    func testNotificationDeliveryWitnessUsesMinimumDelayAndRegistrationCompletion() {
        let now = Date(timeIntervalSinceReferenceDate: 20_000)
        let farEnd = now.addingTimeInterval(30)
        XCTAssertEqual(
            TimerCompletionNotificationTiming.deliveryDelay(
                endDate: farEnd,
                requestCreatedAt: now
            ),
            30
        )

        let registrationCompletedAt = now.addingTimeInterval(0.75)
        let conservativeFarDelivery = TimerCompletionNotificationTiming
            .conservativeDeliveryDate(
                delay: 30,
                registrationCompletedAt: registrationCompletedAt
            )
        XCTAssertEqual(
            conservativeFarDelivery,
            farEnd.addingTimeInterval(0.75)
        )

        let minimumDelay = IntegrationConstants.notificationMinimumDelay
        XCTAssertEqual(
            TimerCompletionNotificationTiming.deliveryDelay(
                endDate: now.addingTimeInterval(0.1),
                requestCreatedAt: now
            ),
            minimumDelay
        )
        XCTAssertEqual(
            TimerCompletionNotificationTiming.deliveryDelay(
                endDate: now.addingTimeInterval(-5),
                requestCreatedAt: now
            ),
            minimumDelay
        )
        let minimumDelivery = TimerCompletionNotificationTiming
            .conservativeDeliveryDate(
                delay: minimumDelay,
                registrationCompletedAt: registrationCompletedAt
            )
        XCTAssertEqual(
            minimumDelivery,
            registrationCompletedAt.addingTimeInterval(minimumDelay)
        )

        XCTAssertFalse(
            TimerCompletionForegroundFeedbackPolicy
                .notificationMayHaveDelivered(
                    isAuthorized: true,
                    expectedDeliveryDate: minimumDelivery,
                    now: now
                )
        )
        XCTAssertTrue(
            TimerCompletionForegroundFeedbackPolicy
                .notificationMayHaveDelivered(
                    isAuthorized: true,
                    expectedDeliveryDate: minimumDelivery,
                    now: minimumDelivery
                )
        )
        XCTAssertFalse(
            TimerCompletionForegroundFeedbackPolicy
                .notificationMayHaveDelivered(
                    isAuthorized: false,
                    expectedDeliveryDate: minimumDelivery,
                    now: minimumDelivery
                )
        )
        XCTAssertFalse(
            TimerCompletionForegroundFeedbackPolicy
                .notificationMayHaveDelivered(
                    isAuthorized: true,
                    expectedDeliveryDate: nil,
                    now: minimumDelivery
                )
        )
    }

    func testTimerCompletionNotificationSoundsAreGeneratedAsShortDistinctCAF() throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent(
            "timer-completion-sounds-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: library,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: library) }

        var payloads: [Data] = []
        for style in TimerCompletionSound.allCases {
            let url = try TimerCompletionSoundLibrary.ensureSoundFile(
                for: style,
                libraryDirectory: library
            )
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Sounds")
            XCTAssertEqual(url.pathExtension, "caf")
            XCTAssertTrue(url.lastPathComponent.contains(style.rawValue))

            let audioFile = try AVAudioFile(forReading: url)
            XCTAssertGreaterThan(audioFile.length, 0)
            XCTAssertLessThan(
                Double(audioFile.length) / audioFile.processingFormat.sampleRate,
                1
            )
            payloads.append(try Data(contentsOf: url))
            XCTAssertEqual(
                try TimerCompletionSoundLibrary.ensureSoundFile(
                    for: style,
                    libraryDirectory: library
                ),
                url,
                "materialization must be idempotent"
            )
        }
        XCTAssertEqual(Set(payloads).count, TimerCompletionSound.allCases.count)
    }

    func testTimerCompletionPreviewCountsThreeTwoOneAndPlaysOnce() async {
        let gate = TimerCompletionPreviewSleepGate()
        let spy = TimerCompletionPreviewPlaybackSpy()
        let controller = TimerCompletionPreviewController(
            sleeper: { try await gate.sleep() },
            playback: { spy.configurations.append($0) }
        )
        let configuration = TimerCompletionPreviewConfiguration(
            sound: .bright,
            haptic: .strong
        )

        controller.start(configuration)
        XCTAssertEqual(controller.state, .countingDown(3))
        await waitForPreviewSleep(gate, count: 1)

        await gate.resumeNext()
        await waitForPreviewState(controller, .countingDown(2))
        await waitForPreviewSleep(gate, count: 1)
        await gate.resumeNext()
        await waitForPreviewState(controller, .countingDown(1))
        await waitForPreviewSleep(gate, count: 1)
        await gate.resumeNext()
        await waitForPreviewState(controller, .idle)

        XCTAssertEqual(spy.configurations, [configuration])
    }

    func testTimerCompletionPreviewCancellationCannotPlay() async {
        let gate = TimerCompletionPreviewSleepGate()
        let spy = TimerCompletionPreviewPlaybackSpy()
        let controller = TimerCompletionPreviewController(
            sleeper: { try await gate.sleep() },
            playback: { spy.configurations.append($0) }
        )

        controller.start(TimerCompletionPreviewConfiguration(
            sound: .soft,
            haptic: .gentle
        ))
        await waitForPreviewSleep(gate, count: 1)
        controller.cancel()
        await gate.resumeNext()
        await Task.yield()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(spy.configurations.isEmpty)
    }

    func testRestartedTimerCompletionPreviewRejectsStaleSelection() async {
        let gate = TimerCompletionPreviewSleepGate()
        let spy = TimerCompletionPreviewPlaybackSpy()
        let controller = TimerCompletionPreviewController(
            sleeper: { try await gate.sleep() },
            playback: { spy.configurations.append($0) }
        )
        let stale = TimerCompletionPreviewConfiguration(
            sound: .soft,
            haptic: .gentle
        )
        let current = TimerCompletionPreviewConfiguration(
            sound: .bright,
            haptic: .strong
        )

        controller.start(stale)
        await waitForPreviewSleep(gate, count: 1)
        controller.start(current)
        await waitForPreviewSleep(gate, count: 2)

        // Resume the cancelled, deliberately non-cooperative old sleeper first.
        await gate.resumeNext()
        await waitForPreviewState(controller, .countingDown(3))
        for expectedState in [
            TimerCompletionPreviewState.countingDown(2),
            .countingDown(1),
            .idle
        ] {
            await waitForPreviewSleep(gate, count: 1)
            await gate.resumeNext()
            await waitForPreviewState(controller, expectedState)
        }

        XCTAssertEqual(spy.configurations, [current])
    }

    func testTimerCompletionAlertRepeatsUntilMatchingSessionStopsIt() async {
        let gate = TimerCompletionAlertSleepGate()
        let spy = TimerCompletionAlertPlaybackSpy()
        let controller = TimerCompletionAlertController(
            sleeper: { try await gate.sleep() },
            playback: { spy.configurations.append($0) },
            stopPlayback: { spy.stopCount += 1 },
            applicationIsActive: { spy.applicationIsActive }
        )
        let sessionID = UUID()
        let configuration = TimerCompletionAlertConfiguration(
            sessionID: sessionID,
            sound: .bright,
            haptic: .strong
        )

        controller.start(configuration)
        XCTAssertTrue(controller.isActive(sessionID: sessionID))
        XCTAssertEqual(spy.configurations, [configuration])
        await waitForCompletionAlertSleep(gate, count: 1)

        await gate.resumeNext()
        await waitForCompletionAlertPlayback(spy, count: 2)
        await waitForCompletionAlertSleep(gate, count: 1)

        controller.stop(sessionID: UUID())
        XCTAssertTrue(controller.isActive(sessionID: sessionID))
        XCTAssertEqual(spy.stopCount, 0)

        controller.stop(sessionID: sessionID)
        XCTAssertFalse(controller.isActive(sessionID: sessionID))
        XCTAssertEqual(spy.stopCount, 1)
        await gate.resumeNext()
        await Task.yield()
        XCTAssertEqual(spy.configurations, [configuration, configuration])
    }

    func testTimerCompletionAlertDelaysReturnCueAndSkipsInactiveCycles() async {
        let gate = TimerCompletionAlertSleepGate()
        let spy = TimerCompletionAlertPlaybackSpy()
        spy.applicationIsActive = false
        let controller = TimerCompletionAlertController(
            sleeper: { try await gate.sleep() },
            playback: { spy.configurations.append($0) },
            stopPlayback: { spy.stopCount += 1 },
            applicationIsActive: { spy.applicationIsActive }
        )
        let configuration = TimerCompletionAlertConfiguration(
            sessionID: UUID(),
            sound: .soft,
            haptic: nil
        )

        controller.start(configuration, playsImmediately: false)
        XCTAssertTrue(controller.isActive(sessionID: configuration.sessionID))
        XCTAssertTrue(spy.configurations.isEmpty)
        await waitForCompletionAlertSleep(gate, count: 1)
        await gate.resumeNext()
        await waitForCompletionAlertSleep(gate, count: 1)
        XCTAssertTrue(spy.configurations.isEmpty)

        spy.applicationIsActive = true
        await gate.resumeNext()
        await waitForCompletionAlertPlayback(spy, count: 1)
        await waitForCompletionAlertSleep(gate, count: 1)
        controller.stop(sessionID: configuration.sessionID)
        await gate.resumeNext()
        await Task.yield()
        XCTAssertEqual(spy.configurations, [configuration])
    }

    func testTimerCompletionAlertIsSilentOnlyWhenBothChannelsAreOff() {
        let spy = TimerCompletionAlertPlaybackSpy()
        let controller = TimerCompletionAlertController(
            sleeper: { try await Task.sleep(for: .seconds(60)) },
            playback: { spy.configurations.append($0) },
            stopPlayback: { spy.stopCount += 1 },
            applicationIsActive: { true }
        )
        let silent = TimerCompletionAlertConfiguration(
            sessionID: UUID(),
            sound: nil,
            haptic: nil
        )

        controller.start(silent)
        XCTAssertFalse(controller.isActive(sessionID: silent.sessionID))
        XCTAssertTrue(spy.configurations.isEmpty)

        let hapticOnly = TimerCompletionAlertConfiguration(
            sessionID: UUID(),
            sound: nil,
            haptic: .standard
        )
        controller.start(hapticOnly)
        XCTAssertEqual(spy.configurations, [hapticOnly])

        let staleSilent = TimerCompletionAlertConfiguration(
            sessionID: UUID(),
            sound: nil,
            haptic: nil
        )
        controller.start(staleSilent)
        XCTAssertTrue(controller.isActive(sessionID: hapticOnly.sessionID))
        XCTAssertEqual(spy.stopCount, 0)

        let matchingSilent = TimerCompletionAlertConfiguration(
            sessionID: hapticOnly.sessionID,
            sound: nil,
            haptic: nil
        )
        controller.start(matchingSilent)
        XCTAssertFalse(controller.isActive(sessionID: hapticOnly.sessionID))
        XCTAssertEqual(spy.stopCount, 1)
    }

    func testPreferenceSafetyTieAndExactStampConflictFailClosed() throws {
        let sharedStamp = orderedUUID(680)
        let active = Prefs(
            rareRewardModeRawValue: RareRewardMode.standard.rawValue,
            rareRewardModeUpdatedAt: Date(timeIntervalSince1970: 10),
            reminderEnabled: true,
            shareIncludesManual: true,
            showsThemeNameExternally: true
        )
        active.syncRecordID = orderedUUID(681)
        active.reminderEnabledRevision = 3
        active.reminderEnabledMutationID = orderedUUID(691)
        active.shareIncludesManualRevision = 3
        active.shareIncludesManualMutationID = orderedUUID(692)
        active.rareRewardRevision = 3
        active.rareRewardMutationID = orderedUUID(693)
        active.externalThemeRevision = 3
        active.externalThemeMutationID = orderedUUID(694)
        let privateCopy = Prefs(
            rareRewardModeRawValue: RareRewardMode.off.rawValue,
            rareRewardModeUpdatedAt: Date(timeIntervalSince1970: 20),
            reminderEnabled: false,
            shareIncludesManual: false,
            showsThemeNameExternally: false
        )
        privateCopy.syncRecordID = orderedUUID(682)
        privateCopy.reminderEnabledRevision = 3
        privateCopy.reminderEnabledMutationID = orderedUUID(690)
        privateCopy.shareIncludesManualRevision = 3
        privateCopy.shareIncludesManualMutationID = orderedUUID(689)
        privateCopy.rareRewardRevision = 3
        privateCopy.rareRewardMutationID = orderedUUID(688)
        privateCopy.externalThemeRevision = 3
        privateCopy.externalThemeMutationID = orderedUUID(687)

        let resolved = try PrefsSyncPolicy.resolvedState(
            in: [active, privateCopy],
            currentEpochID: nil
        )
        XCTAssertFalse(resolved.reminderEnabled)
        XCTAssertFalse(resolved.shareIncludesManual)
        XCTAssertFalse(resolved.showsThemeNameExternally)
        XCTAssertEqual(resolved.rareRewardModeRawValue, RareRewardMode.off.rawValue)

        active.soundRevision = 9
        active.soundMutationID = sharedStamp
        active.soundOn = true
        privateCopy.soundRevision = 9
        privateCopy.soundMutationID = sharedStamp
        privateCopy.soundOn = false
        XCTAssertThrowsError(
            try PrefsSyncPolicy.resolvedState(
                in: [active, privateCopy],
                currentEpochID: nil
            )
        ) {
            XCTAssertEqual($0 as? PrefsSyncError, .conflictingStampedValues)
        }
    }

    func testPreferenceMutationWritesOnlyOwnedRowAndRejectsRevisionLimit() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let owned = Prefs(
            soundOn: true,
            hapticsOn: true,
            settingsWriterID: "device-a"
        )
        owned.syncRecordID = orderedUUID(700)
        owned.soundRevision = 1
        owned.soundMutationID = orderedUUID(710)
        let foreign = Prefs(
            soundOn: true,
            hapticsOn: false,
            settingsWriterID: "device-b"
        )
        foreign.syncRecordID = orderedUUID(701)
        foreign.hapticsRevision = 4
        foreign.hapticsMutationID = orderedUUID(711)
        context.insert(owned)
        context.insert(foreign)
        try context.save()
        let foreignBefore = prefsFingerprint(foreign)

        let written = try PrefsSyncPolicy.mutate(
            .sound,
            in: [owned, foreign],
            context: context,
            writerID: "device-a",
            currentEpochID: nil,
            currentDay: "2026-09-04",
            canonicalID: SyncMaintenanceCanonicalIDs.preferences,
            mutationID: orderedUUID(712)
        ) { $0.soundOn = false }
        XCTAssertTrue(written === owned)
        XCTAssertFalse(owned.soundOn)
        XCTAssertEqual(owned.soundRevision, 2)
        XCTAssertFalse(owned.hapticsOn, "observed independent winner is copied to owned row")
        XCTAssertEqual(owned.hapticsRevision, 4)
        XCTAssertEqual(prefsFingerprint(foreign), foreignBefore)

        owned.soundRevision = PrefsSyncPolicy.maximumSupportedRevision
        owned.soundMutationID = orderedUUID(713)
        let ownedBeforeLimit = prefsFingerprint(owned)
        var updateRan = false
        XCTAssertThrowsError(
            try PrefsSyncPolicy.mutate(
                .sound,
                in: [owned, foreign],
                context: context,
                writerID: "device-a",
                currentEpochID: nil,
                mutationID: orderedUUID(714)
            ) { value in
                updateRan = true
                value.soundOn = true
            }
        ) {
            XCTAssertEqual($0 as? PrefsSyncError, .revisionLimitReached)
        }
        XCTAssertFalse(updateRan)
        XCTAssertEqual(prefsFingerprint(owned), ownedBeforeLimit)
        XCTAssertEqual(prefsFingerprint(foreign), foreignBefore)
    }

    func testV2LedgerCursorOverridesLegacyGachaHistory() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(GachaState(
            id: SyncMaintenanceCanonicalIDs.gacha,
            sinceLastGold: 99,
            rewardCreditGrams: 1_250,
            dataEpochID: nil
        ))
        context.insert(makeSession(
            id: UUID(),
            grams: 250,
            kind: .normal,
            epochID: nil
        ))

        let migration = RareRewardLedgerMigration.legacy(
            dataEpochID: nil,
            totalCreditedGrams: 0,
            sinceLastGold: 0
        )
        let receipt = RareRewardLedgerReceipt(
            epochID: migration.epochID,
            sessionID: UUID(),
            submissionFingerprint: "test-submission",
            participated: true,
            nonparticipationReason: nil,
            acceptedGrams: 500,
            firstOrdinal: 0,
            ordinalCount: 2,
            outcomes: [.gold, .normal],
            revisionBefore: 0,
            revisionAfter: 1,
            totalCreditedGramsAfter: 500,
            creditRemainderGramsAfter: 0,
            sinceLastGoldAfter: 1
        )
        context.insert(RareRewardLedgerCursor(
            dataEpochID: nil,
            migration: migration,
            receipt: receipt
        ))
        try context.save()

        let result = try await SyncMaintenanceSliceWorker(
            modelContainer: container
        ).run(SyncMaintenanceSliceRequest(
            kind: .gacha,
            generation: 1,
            cursor: nil,
            limits: .production,
            includesRareRewardLedgerMaintenance: true
        ))

        XCTAssertEqual(result.disposition, .completed)
        assertBudget(result.audit)
        let state = try XCTUnwrap(
            try context.fetch(FetchDescriptor<GachaState>()).first
        )
        XCTAssertEqual(state.rewardCreditGrams, 500)
        XCTAssertEqual(state.sinceLastGold, 1)
        XCTAssertEqual(
            result.audit.totalRowsAccessed,
            2,
            "V2 authority must avoid reading the legacy session tail"
        )
    }

    func testBedrockCompactionDoesNotRacePreferenceLifecycleWriter() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(Prefs(id: SyncMaintenanceCanonicalIDs.preferences))
        context.insert(Bedrock(
            hours: 40,
            importedAt: Date(timeIntervalSince1970: 20)
        ))
        context.insert(Bedrock(
            hours: 120,
            importedAt: Date(timeIntervalSince1970: 10)
        ))
        try context.save()

        let firstRequest = SyncMaintenanceSliceRequest(
            kind: .bedrock,
            generation: 1,
            cursor: nil,
            limits: .production
        )
        let first = try await SyncMaintenanceSliceWorker(
            modelContainer: container
        ).run(firstRequest)
        XCTAssertEqual(first.disposition, .moreWork)
        XCTAssertEqual(first.nextCursor?.phase, 1)
        XCTAssertEqual(first.audit.saveCount, 1)
        assertBudget(first.audit)

        var bedrocks = try context.fetch(FetchDescriptor<Bedrock>())
        XCTAssertEqual(bedrocks.count, 1)
        XCTAssertEqual(bedrocks.first?.hours, 120)
        var prefs = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Prefs>()).first
        )
        XCTAssertFalse(
            prefs.hasEverImportedBedrock,
            "the local-store save must not also mutate cloud preferences"
        )

        let replayedFirst = try await SyncMaintenanceSliceWorker(
            modelContainer: container
        ).run(firstRequest)
        XCTAssertEqual(replayedFirst.disposition, .moreWork)
        XCTAssertEqual(replayedFirst.nextCursor?.phase, 1)
        XCTAssertEqual(replayedFirst.audit.saveCount, 0)
        bedrocks = try context.fetch(FetchDescriptor<Bedrock>())
        XCTAssertEqual(bedrocks.count, 1)

        let secondRequest = SyncMaintenanceSliceRequest(
            kind: .bedrock,
            generation: 1,
            cursor: try XCTUnwrap(first.nextCursor),
            limits: .production
        )
        let second = try await SyncMaintenanceSliceWorker(
            modelContainer: container
        ).run(secondRequest)
        XCTAssertEqual(second.disposition, .completed)
        XCTAssertEqual(second.audit.saveCount, 0)
        assertBudget(second.audit)
        prefs = try XCTUnwrap(try context.fetch(FetchDescriptor<Prefs>()).first)
        XCTAssertFalse(
            prefs.hasEverImportedBedrock,
            "background maintenance must not overwrite the MainActor-owned settings row"
        )

        let replayedSecond = try await SyncMaintenanceSliceWorker(
            modelContainer: container
        ).run(secondRequest)
        XCTAssertEqual(replayedSecond.disposition, .completed)
        XCTAssertEqual(replayedSecond.audit.saveCount, 0)
    }

    func testDistinctOfflineCompletionIDsRemainMeasured() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let firstID = orderedUUID(1)
        let secondID = orderedUUID(2)
        context.insert(makeSession(id: firstID, grams: 100, epochID: nil))
        context.insert(makeSession(id: secondID, grams: 100, epochID: nil))
        try context.save()

        let request = SyncMaintenanceSliceRequest(
            kind: .sessions,
            generation: 1,
            cursor: nil,
            limits: .production
        )
        let result = try await SyncMaintenanceSliceWorker(
            modelContainer: container
        ).run(request)

        XCTAssertEqual(result.disposition, .completed)
        let sessions = try context.fetch(FetchDescriptor<StudySession>())
        XCTAssertEqual(Set(sessions.map(\.id)), [firstID, secondID])
        XCTAssertTrue(sessions.allSatisfy { $0.source == .timer })
    }

    func testCleanSessionPageIsReadOnly() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        for index in 0 ..< 128 {
            context.insert(makeSession(
                id: orderedUUID(100_000 + index),
                grams: 250,
                epochID: nil
            ))
        }
        try context.save()

        let result = try await SyncMaintenanceSliceWorker(
            modelContainer: container
        ).run(SyncMaintenanceSliceRequest(
            kind: .sessions,
            generation: 1,
            cursor: nil,
            limits: .production
        ))

        XCTAssertEqual(result.disposition, .moreWork)
        XCTAssertEqual(result.audit.saveCount, 0)
        XCTAssertTrue(result.mainActorEffects.isEmpty)
        XCTAssertTrue(result.followupKinds.isEmpty)
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<StudySession>()),
            128
        )
    }

    func testReadOnlyFocusMaintenanceRefreshesDelayedTimerOutsideRootSentinel() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date.now.addingTimeInterval(-600)
        for index in 0 ..< 64 {
            let start = base.addingTimeInterval(100 + TimeInterval(index))
            let timer = try makeFocusTimer(
                recordID: orderedUUID(21_000 + index),
                sessionID: orderedUUID(22_000 + index),
                start: start,
                updatedAt: start,
                revision: 1,
                ownershipSequence: 0,
                writer: "history-device"
            )
            timer.markTerminal(
                .cancelled,
                at: start.addingTimeInterval(1),
                writerDeviceID: "history-device"
            )
            context.insert(timer)
        }
        try context.save()

        // Root observes only the newest 64 timer rows. An older timer can
        // legitimately arrive later from a device that was previously offline.
        var sentinel = FetchDescriptor<SyncedFocusTimer>(sortBy: [
            SortDescriptor(\SyncedFocusTimer.updatedAt, order: .reverse)
        ])
        sentinel.fetchLimit = 64
        let beforeImport = try context.fetch(sentinel).map(\.policySnapshot)
        XCTAssertNil(try FocusCloudSyncStore.canonicalActive(context: context))

        let delayedSessionID = orderedUUID(23_000)
        context.insert(try makeFocusTimer(
            recordID: orderedUUID(23_001),
            sessionID: delayedSessionID,
            start: base,
            updatedAt: base,
            revision: 1,
            ownershipSequence: 0,
            writer: "previously-offline-device"
        ))
        try context.save()
        XCTAssertEqual(try context.fetch(sentinel).map(\.policySnapshot), beforeImport)
        XCTAssertEqual(
            try FocusCloudSyncStore.canonicalActive(context: context)?.sessionID,
            delayedSessionID
        )

        let results = try await runFocusMaintenance(
            container: container,
            generation: 39,
            maximumSlices: 8
        )
        let completion = try XCTUnwrap(results.last)
        XCTAssertEqual(completion.disposition, .completed)
        XCTAssertTrue(
            completion.mainActorEffects.contains(.reevaluateLocalFocus),
            "Read-only import verification must wake Root's bounded recovery query"
        )
        XCTAssertTrue(results.allSatisfy { $0.audit.saveCount == 0 })
        XCTAssertEqual(try context.fetch(sentinel).map(\.policySnapshot), beforeImport)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncedFocusTimer>()), 65)
    }

    func testOversizedFocusClaimGroupFailsClosedWithoutSourceCompaction() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let claimID = orderedUUID(30_000)
        let sessionID = orderedUUID(30_001)
        let base = Date(timeIntervalSince1970: 1_810_000_000)
        var original: [FocusTimerDeviceClaim] = []

        for index in 0 ..< 1_000 {
            let sequence = index == 999 ? 100 : index % 101
            let releasedAt = index.isMultiple(of: 137)
                ? base.addingTimeInterval(10_000 + TimeInterval(index))
                : nil
            let claim = FocusTimerDeviceClaim(
                id: claimID,
                sessionID: sessionID,
                deviceID: index == 999 ? "owner-z" : "device-\(index)",
                sequence: sequence,
                claimedAt: base.addingTimeInterval(TimeInterval(index)),
                releasedAt: releasedAt
            )
            original.append(claim)
            context.insert(claim)
        }

        let originalFingerprint = original.map(claimFingerprint).sorted()
        try context.save()

        let phaseZero = try await SyncMaintenanceSliceWorker(
            modelContainer: container
        ).run(SyncMaintenanceSliceRequest(
            kind: .focusFairness,
            generation: 40,
            cursor: nil,
            limits: .production
        ))
        assertBudget(phaseZero.audit)
        XCTAssertEqual(phaseZero.disposition, .moreWork)
        XCTAssertEqual(phaseZero.nextCursor?.phase, 1)

        let auditRequest = SyncMaintenanceSliceRequest(
            kind: .focusFairness,
            generation: 40,
            cursor: try XCTUnwrap(phaseZero.nextCursor),
            limits: .production
        )
        let firstAudit = try await SyncMaintenanceSliceWorker(
            modelContainer: container
        ).run(auditRequest)
        assertBudget(firstAudit.audit)
        XCTAssertEqual(firstAudit.disposition, .retry)
        XCTAssertEqual(
            firstAudit.failureCategory,
            "oversized-focus-claim-logical-group"
        )
        XCTAssertEqual(firstAudit.audit.saveCount, 0)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FocusTimerDeviceClaim>())
                .map(claimFingerprint).sorted(),
            originalFingerprint
        )

        // Replaying a rejected checkpoint is also read-only. No observed page
        // is allowed to destroy a release carried by an unseen third copy.
        let replay = try await SyncMaintenanceSliceWorker(
            modelContainer: container
        ).run(auditRequest)
        XCTAssertEqual(replay.disposition, .retry)
        XCTAssertEqual(replay.failureCategory, firstAudit.failureCategory)
        XCTAssertEqual(replay.audit.saveCount, 0)
        XCTAssertEqual(
            try context.fetch(FetchDescriptor<FocusTimerDeviceClaim>())
                .map(claimFingerprint).sorted(),
            originalFingerprint
        )
        XCTAssertNil(
            FocusSyncPolicy.notificationOwner(
                for: sessionID,
                claims: original.map(\.policySnapshot)
            ),
            "the full-set release remains visible because no physical copy was deleted"
        )
    }

    func testInvalidClaimSequenceCannotOverwriteValidOwner() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let claimID = orderedUUID(31_000)
        let sessionID = orderedUUID(31_001)
        let base = Date(timeIntervalSince1970: 1_811_000_000)
        context.insert(FocusTimerDeviceClaim(
            id: claimID,
            sessionID: sessionID,
            deviceID: "A",
            sequence: 7,
            claimedAt: base
        ))
        context.insert(FocusTimerDeviceClaim(
            id: claimID,
            sessionID: sessionID,
            deviceID: "corrupt",
            sequence: FocusSyncPolicy.maximumSupportedOwnershipSequence + 1,
            claimedAt: base.addingTimeInterval(10_000)
        ))
        try context.save()

        var claims = try context.fetch(FetchDescriptor<FocusTimerDeviceClaim>())
        XCTAssertEqual(
            FocusSyncPolicy.notificationOwner(
                for: sessionID,
                claims: claims.map(\.policySnapshot)
            ),
            "A"
        )

        let results = try await runFocusMaintenance(
            container: container,
            generation: 42,
            maximumSlices: 8
        )
        XCTAssertEqual(results.last?.disposition, .completed)
        claims = try context.fetch(FetchDescriptor<FocusTimerDeviceClaim>())
        XCTAssertEqual(
            claims.count,
            2,
            "invalid source evidence remains quarantined rather than physically deleted"
        )
        XCTAssertTrue(claims.contains { $0.sequence == 7 })
        XCTAssertTrue(claims.contains {
            $0.sequence == FocusSyncPolicy.maximumSupportedOwnershipSequence + 1
        })
        XCTAssertTrue(results.allSatisfy { $0.audit.saveCount == 0 })
        XCTAssertEqual(
            FocusSyncPolicy.notificationOwner(
                for: sessionID,
                claims: claims.map(\.policySnapshot)
            ),
            "A"
        )
    }

    func testEqualFocusClaimCopiesUseStablePhysicalTotalOrder() {
        let claimID = orderedUUID(31_100)
        let sessionID = orderedUUID(31_101)
        let claimedAt = Date(timeIntervalSince1970: 100)
        let low = FocusOwnershipClaimSnapshot(
            id: claimID,
            syncRecordID: orderedUUID(31_102),
            sessionID: sessionID,
            deviceID: "device-A",
            sequence: 7,
            claimedAt: claimedAt,
            releasedAt: nil
        )
        let high = FocusOwnershipClaimSnapshot(
            id: claimID,
            syncRecordID: orderedUUID(31_103),
            sessionID: sessionID,
            deviceID: "device-A",
            sequence: 7,
            claimedAt: claimedAt,
            releasedAt: nil
        )

        XCTAssertEqual(
            FocusSyncPolicy.notificationOwnerClaim(
                for: sessionID,
                claims: [low, high]
            )?.syncRecordID,
            high.syncRecordID
        )
        XCTAssertEqual(
            FocusSyncPolicy.notificationOwnerClaim(
                for: sessionID,
                claims: [high, low]
            )?.syncRecordID,
            high.syncRecordID
        )
    }

    func testClosedFocusTimerTailsNoLongerHideLaterActiveTimer() async throws {
        for closedCount in [65, 129, 257] {
            let container = try makeContainer()
            let context = container.mainContext
            let base = Date(timeIntervalSince1970: 1_812_000_000)
            let idBase = closedCount == 65 ? 40_000 : 50_000

            for index in 0 ..< closedCount {
                let sessionID = orderedUUID(idBase + index)
                context.insert(makeSession(id: sessionID, grams: 1, epochID: nil))
                context.insert(try makeFocusTimer(
                    recordID: orderedUUID(100_000 + idBase + index),
                    sessionID: sessionID,
                    start: base.addingTimeInterval(TimeInterval(index)),
                    updatedAt: base.addingTimeInterval(TimeInterval(index)),
                    revision: 1,
                    ownershipSequence: 1,
                    writer: "stale-\(index)"
                ))
            }
            let activeSessionID = orderedUUID(idBase + closedCount)
            context.insert(try makeFocusTimer(
                recordID: orderedUUID(200_000 + idBase),
                sessionID: activeSessionID,
                start: base.addingTimeInterval(TimeInterval(closedCount + 1)),
                updatedAt: base.addingTimeInterval(TimeInterval(closedCount + 1)),
                revision: 1,
                ownershipSequence: 1,
                writer: "valid-active"
            ))
            try context.save()

            if closedCount > FocusCloudSyncStore.QueryContract.logicalTimerScanLimit {
                XCTAssertThrowsError(
                    try FocusCloudSyncStore.canonicalActive(context: context)
                ) {
                    XCTAssertEqual(
                        $0 as? FocusCloudSyncError,
                        .timerHistoryRequiresMaintenance
                    )
                }
            } else {
                XCTAssertEqual(
                    try FocusCloudSyncStore.canonicalActive(context: context)?.sessionID,
                    activeSessionID
                )
            }

            let results = try await runFocusMaintenance(
                container: container,
                generation: UInt64(50 + closedCount),
                maximumSlices: (closedCount * 2) + 24
            )
            XCTAssertEqual(results.last?.disposition, .completed)
            let canonical = try XCTUnwrap(
                try FocusCloudSyncStore.canonicalActive(context: context)
            )
            XCTAssertEqual(canonical.sessionID, activeSessionID)
            let timers = try context.fetch(FetchDescriptor<SyncedFocusTimer>())
            XCTAssertEqual(timers.filter { $0.status.isRecoverable }.count, 1)
            XCTAssertEqual(timers.first?.sessionID, activeSessionID)
        }
    }

    func testFocusTimerSingletonHistoryConvergesInBoundedPages() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 1_812_700_000)
        for index in 0 ..< 1_000 {
            let instant = base.addingTimeInterval(TimeInterval(index))
            let timer = try makeFocusTimer(
                recordID: orderedUUID(250_000 + index),
                sessionID: orderedUUID(57_000 + index),
                start: instant,
                updatedAt: instant,
                revision: 1,
                ownershipSequence: 1,
                writer: "terminal-\(index)"
            )
            timer.status = .cancelled
            timer.terminalAt = instant
            context.insert(timer)
        }
        try context.save()

        let results = try await runFocusMaintenance(
            container: container,
            generation: 57,
            maximumSlices: 24
        )

        XCTAssertEqual(results.last?.disposition, .completed)
        XCTAssertLessThanOrEqual(
            results.count,
            24,
            "singleton history must be processed by bounded pages, not one launch per row"
        )
        XCTAssertTrue(results.allSatisfy { result in
            assertBudget(result.audit)
            return result.audit.saveCount == 0
        })
        XCTAssertEqual(
            try context.fetchCount(FetchDescriptor<SyncedFocusTimer>()),
            1_000
        )
    }

    func testOversizedFocusTimerValidatesReadOnlyAndReplaysSafely() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let sessionID = orderedUUID(58_000)
        let base = Date(timeIntervalSince1970: 1_812_800_000)
        var snapshots: [FocusSyncRecordSnapshot] = []
        for index in 0 ..< 1_000 {
            // Copies 255/256 are exactly policy- and payload-equal and land on
            // opposite validation pages. Other rows mix active, completion,
            // and cancellation categories; the earliest cancellation and
            // preferred pending completion live far apart in the full scan.
            let sourceIndex = index == 256 ? 255 : index
            let start = base.addingTimeInterval(TimeInterval(sourceIndex))
            let timer: SyncedFocusTimer
            switch sourceIndex % 3 {
            case 0:
                timer = try makeFocusTimer(
                    recordID: orderedUUID(258_000 + sourceIndex),
                    sessionID: sessionID,
                    start: start,
                    updatedAt: start,
                    revision: sourceIndex + 1,
                    ownershipSequence: sourceIndex,
                    writer: "running-\(sourceIndex)"
                )
            case 1:
                timer = try makePendingFocusTimer(
                    recordID: orderedUUID(258_000 + sourceIndex),
                    sessionID: sessionID,
                    start: start,
                    writer: "pending-\(sourceIndex)"
                )
                timer.revision = sourceIndex + 1
                timer.ownershipSequence = sourceIndex
            default:
                timer = try makeFocusTimer(
                    recordID: orderedUUID(258_000 + sourceIndex),
                    sessionID: sessionID,
                    start: start,
                    updatedAt: start,
                    revision: sourceIndex + 1,
                    ownershipSequence: sourceIndex,
                    writer: "cancelled-\(sourceIndex)"
                )
                timer.status = .cancelled
                timer.terminalAt = timer.updatedAt
            }
            snapshots.append(timer.policySnapshot)
            context.insert(timer)
        }
        let oracle = try XCTUnwrap(FocusSyncPolicy.resolveSameSession(snapshots))
        try context.save()

        var cursor: SyncMaintenanceCursor?
        var terminal: SyncMaintenanceSliceResult?
        var replayedValidation = false
        for _ in 0 ..< 48 {
            let request = SyncMaintenanceSliceRequest(
                kind: .focusFairness,
                generation: 58,
                cursor: cursor,
                limits: .production
            )
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(request)
            assertBudget(result.audit)
            XCTAssertEqual(result.audit.saveCount, 0)
            XCTAssertEqual(
                try context.fetchCount(FetchDescriptor<SyncedFocusTimer>()),
                1_000,
                "active source validation must be entirely non-destructive"
            )

            if !replayedValidation,
               result.nextCursor?.phase == 0,
               result.nextCursor?.offset == 256,
               result.audit.saveCount == 0 {
                let replay = try await SyncMaintenanceSliceWorker(
                    modelContainer: container
                ).run(request)
                assertBudget(replay.audit)
                XCTAssertEqual(replay.audit.saveCount, 0)
                XCTAssertEqual(replay.nextCursor, result.nextCursor)
                XCTAssertEqual(
                    try context.fetchCount(FetchDescriptor<SyncedFocusTimer>()),
                    1_000
                )
                cursor = replay.nextCursor
                replayedValidation = true
                continue
            }

            if result.disposition == .completed {
                terminal = result
                break
            }
            XCTAssertNotEqual(result.disposition, .retry)
            cursor = result.nextCursor
        }

        XCTAssertEqual(terminal?.disposition, .completed)
        XCTAssertTrue(replayedValidation)
        let retained = try context.fetch(FetchDescriptor<SyncedFocusTimer>())
        XCTAssertEqual(Set(retained.map(\.policySnapshot)), Set(snapshots))
        XCTAssertEqual(
            FocusSyncPolicy.resolveSameSession(retained.map(\.policySnapshot)),
            oracle
        )

        let replay = try await runFocusMaintenance(
            container: container,
            generation: 59,
            maximumSlices: 16
        )
        XCTAssertEqual(replay.last?.disposition, .completed)
        XCTAssertTrue(replay.allSatisfy { $0.audit.saveCount == 0 })
        XCTAssertEqual(
            Set(try context.fetch(FetchDescriptor<SyncedFocusTimer>())
                .map(\.policySnapshot)),
            Set(snapshots)
        )
    }

    func testRearPageTimerPayloadConflictDoesNotDeleteEarlierRevisions() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let conflictSessionID = orderedUUID(59_000)
        let laterSessionID = orderedUUID(59_001)
        let base = Date(timeIntervalSince1970: 1_812_900_000)
        for index in 0 ..< 998 {
            context.insert(try makeFocusTimer(
                recordID: orderedUUID(359_000 + index),
                sessionID: conflictSessionID,
                start: base,
                updatedAt: base.addingTimeInterval(TimeInterval(index)),
                revision: index + 1,
                ownershipSequence: index,
                writer: "valid-prefix-\(index)"
            ))
        }
        let sharedID = orderedUUID(999_000)
        context.insert(try makeFocusTimer(
            recordID: sharedID,
            sessionID: conflictSessionID,
            start: base,
            updatedAt: base.addingTimeInterval(2_000),
            revision: 2_000,
            ownershipSequence: 2_000,
            writer: "same-policy",
            subjectName: "数学"
        ))
        context.insert(try makeFocusTimer(
            recordID: sharedID,
            sessionID: conflictSessionID,
            start: base,
            updatedAt: base.addingTimeInterval(2_000),
            revision: 2_000,
            ownershipSequence: 2_000,
            writer: "same-policy",
            subjectName: "英語"
        ))
        context.insert(try makeFocusTimer(
            recordID: orderedUUID(999_001),
            sessionID: laterSessionID,
            start: base.addingTimeInterval(10_000),
            updatedAt: base.addingTimeInterval(10_000),
            revision: 1,
            ownershipSequence: 1,
            writer: "later-valid"
        ))
        try context.save()

        func conflictFingerprint() throws -> [String] {
            try context.fetch(FetchDescriptor<SyncedFocusTimer>())
                .filter { $0.sessionID == conflictSessionID }
                .map {
                    [
                        $0.id.uuidString,
                        $0.statusRaw,
                        String($0.revision),
                        String($0.ownershipSequence),
                        $0.writerDeviceID,
                        $0.payloadData.base64EncodedString()
                    ].joined(separator: "|")
                }
                .sorted()
        }
        let original = try conflictFingerprint()

        var cursor: SyncMaintenanceCursor?
        var quarantined = false
        for _ in 0 ..< 8 {
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(SyncMaintenanceSliceRequest(
                kind: .focusFairness,
                generation: 59,
                cursor: cursor,
                limits: .production
            ))
            assertBudget(result.audit)
            XCTAssertEqual(result.audit.saveCount, 0)
            XCTAssertEqual(try conflictFingerprint(), original)
            cursor = result.nextCursor
            if result.nextCursor?.phase == 0,
               result.nextCursor?.targetLogicalID == nil,
               result.nextCursor?.lastLogicalID == conflictSessionID {
                quarantined = true
                break
            }
        }
        XCTAssertTrue(quarantined, "the conflict must be found on a rear page")
        XCTAssertEqual(original.count, 1_000)

        var terminal: SyncMaintenanceSliceResult?
        for _ in 0 ..< 12 {
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(SyncMaintenanceSliceRequest(
                kind: .focusFairness,
                generation: 59,
                cursor: cursor,
                limits: .production
            ))
            assertBudget(result.audit)
            XCTAssertEqual(result.audit.saveCount, 0)
            if result.disposition != .moreWork {
                terminal = result
                break
            }
            cursor = result.nextCursor
        }
        XCTAssertEqual(terminal?.disposition, .retry)
        XCTAssertEqual(terminal?.failureCategory, "quarantined-focus-timer-payload")
        XCTAssertEqual(try conflictFingerprint(), original)
        let timers = try context.fetch(FetchDescriptor<SyncedFocusTimer>())
        XCTAssertEqual(timers.filter { $0.sessionID == laterSessionID }.count, 1)
    }

    func testConflictingTimerPayloadAndLaterHistoryRemainNonDestructive() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let conflictSessionID = orderedUUID(60_000)
        let historySessionID = orderedUUID(60_001)
        let sharedRecordID = orderedUUID(160_000)
        let base = Date(timeIntervalSince1970: 1_813_000_000)
        let first = try makeFocusTimer(
            recordID: sharedRecordID,
            sessionID: conflictSessionID,
            start: base,
            updatedAt: base,
            revision: 7,
            ownershipSequence: 7,
            writer: "same-writer"
        )
        let second = try makeFocusTimer(
            recordID: sharedRecordID,
            sessionID: conflictSessionID,
            start: base,
            updatedAt: base,
            revision: 7,
            ownershipSequence: 7,
            writer: "same-writer"
        )
        // JSON object key order is not an identity contract. Begin from truly
        // identical bytes, then introduce exactly one payload-only conflict.
        second.payloadData = first.payloadData
        // Reverse insertion makes it especially important that neither the
        // fetch order nor exact.first is treated as a conflict-resolution rule.
        context.insert(second)
        context.insert(first)
        for index in 0 ..< 1_000 {
            context.insert(try makeFocusTimer(
                recordID: orderedUUID(300_000 + index),
                sessionID: historySessionID,
                start: base.addingTimeInterval(20_000),
                updatedAt: base.addingTimeInterval(20_000 + TimeInterval(index)),
                revision: index + 1,
                ownershipSequence: index,
                writer: "valid-\(index)"
            ))
        }
        try context.save()

        // Corrupt exactly the row selected by the interactive policy while
        // leaving every policy field equal. The other copy remains valid.
        let selectedBefore = try XCTUnwrap(
            try FocusCloudSyncStore.canonicalActive(context: context)
        )
        selectedBefore.payloadData = Data([0xFF, 0x00, 0xFE])
        try context.save()
        XCTAssertEqual(
            try FocusCloudSyncStore.canonicalActive(context: context)?.sessionID,
            historySessionID,
            "A corrupt group must not hide a valid multi-page timer history"
        )

        let results = try await runFocusMaintenance(
            container: container,
            generation: 60,
            maximumSlices: 24
        )
        XCTAssertEqual(results.last?.disposition, .retry)
        XCTAssertEqual(
            results.last?.failureCategory,
            "quarantined-focus-timer-payload"
        )
        XCTAssertTrue(results.dropLast().allSatisfy {
            $0.disposition == .moreWork
        })

        let timers = try context.fetch(FetchDescriptor<SyncedFocusTimer>())
        let conflicted = timers.filter { $0.sessionID == conflictSessionID }
        let retainedHistory = timers.filter { $0.sessionID == historySessionID }
        XCTAssertEqual(conflicted.count, 2, "quarantine must be non-destructive")
        XCTAssertEqual(Set(conflicted.map(\.payloadData)).count, 2)
        XCTAssertEqual(
            retainedHistory.count,
            1_000,
            "a clean group is still source evidence and is never physically compacted"
        )
        XCTAssertTrue(retainedHistory.allSatisfy {
            (try? $0.decodedPayload()) != nil
        })
        XCTAssertTrue(results.allSatisfy { $0.audit.saveCount == 0 })
        XCTAssertEqual(
            try FocusCloudSyncStore.canonicalActive(context: context)?.sessionID,
            historySessionID,
            "A corrupt group must not hide a valid multi-page timer history"
        )
    }

    func test129MismatchedRunningAndPendingSessionsDoNotStarveValidTimer() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 1_814_000_000)
        let mismatchCount = 129
        var mismatchedRowIDs = Set<UUID>()
        for index in 0 ..< mismatchCount {
            let payloadSessionID = orderedUUID(80_000 + index)
            let rowSessionID = orderedUUID(70_000 + index)
            let start = base.addingTimeInterval(TimeInterval(index))
            let timer = index.isMultiple(of: 2)
                ? try makeFocusTimer(
                    recordID: orderedUUID(170_000 + index),
                    sessionID: payloadSessionID,
                    start: start,
                    updatedAt: start,
                    revision: 1,
                    ownershipSequence: 1,
                    writer: "corrupt-running-\(index)"
                )
                : try makePendingFocusTimer(
                    recordID: orderedUUID(170_000 + index),
                    sessionID: payloadSessionID,
                    start: start,
                    writer: "corrupt-pending-\(index)"
                )
            timer.sessionID = rowSessionID
            mismatchedRowIDs.insert(rowSessionID)
            context.insert(timer)
        }
        let validSessionID = orderedUUID(70_000 + mismatchCount)
        let valid = try makeFocusTimer(
            recordID: orderedUUID(170_002),
            sessionID: validSessionID,
            start: base.addingTimeInterval(5_000),
            updatedAt: base.addingTimeInterval(5_000),
            revision: 1,
            ownershipSequence: 1,
            writer: "valid-later"
        )
        context.insert(valid)
        try context.save()

        let corruptBefore = try context.fetch(FetchDescriptor<SyncedFocusTimer>())
            .filter { mismatchedRowIDs.contains($0.sessionID) }
        XCTAssertEqual(corruptBefore.count, mismatchCount)
        XCTAssertTrue(corruptBefore.allSatisfy {
            do {
                _ = try $0.decodedPayload()
                return false
            } catch FocusCloudSyncError.invalidPayload {
                return true
            } catch {
                return false
            }
        })
        XCTAssertEqual(
            try FocusCloudSyncStore.canonicalActive(context: context)?.sessionID,
            validSessionID,
            "129 invalid logical sessions must not consume the global scan result"
        )

        let results = try await runFocusMaintenance(
            container: container,
            generation: 61,
            maximumSlices: (mismatchCount * 2) + 20
        )
        XCTAssertEqual(results.last?.disposition, .retry)
        XCTAssertEqual(
            results.last?.failureCategory,
            "quarantined-focus-timer-payload"
        )
        XCTAssertTrue(results.allSatisfy { $0.audit.saveCount == 0 })

        let timers = try context.fetch(FetchDescriptor<SyncedFocusTimer>())
        XCTAssertEqual(timers.count, mismatchCount + 1, "quarantine is non-destructive")
        XCTAssertEqual(
            timers.filter {
                mismatchedRowIDs.contains($0.sessionID) && $0.status == .running
            }.count,
            65
        )
        XCTAssertEqual(
            timers.filter {
                mismatchedRowIDs.contains($0.sessionID)
                    && $0.status == .completionPending
            }.count,
            64
        )
        XCTAssertEqual(
            try FocusCloudSyncStore.canonicalActive(context: context)?.sessionID,
            validSessionID
        )
    }

    func testInvalidTerminalAndUnknownSingletonsQuarantineInEitherInsertionOrder() async throws {
        for corruptionIndex in 0 ..< 3 {
            for reverseInsertion in [false, true] {
                let container = try makeContainer()
                let context = container.mainContext
                let base = Date(timeIntervalSince1970: 1_814_500_000)
                    .addingTimeInterval(TimeInterval(corruptionIndex * 100))
                let idBase = 72_000 + (corruptionIndex * 10)
                let validSessionID = orderedUUID(idBase)
                let corruptSessionID = orderedUUID(idBase + 1)
                let payloadSessionID = orderedUUID(idBase + 2)
                let valid = try makeFocusTimer(
                    recordID: orderedUUID(172_000 + (corruptionIndex * 10)),
                    sessionID: validSessionID,
                    start: base,
                    updatedAt: base,
                    revision: 1,
                    ownershipSequence: 1,
                    writer: "valid-A"
                )

                let corrupt: SyncedFocusTimer
                switch corruptionIndex {
                case 0:
                    corrupt = try makePendingFocusTimer(
                        recordID: orderedUUID(172_001 + (corruptionIndex * 10)),
                        sessionID: payloadSessionID,
                        start: base.addingTimeInterval(10),
                        writer: "corrupt-completed"
                    )
                    corrupt.status = .completed
                    corrupt.terminalAt = corrupt.scheduledEndAt ?? corrupt.updatedAt
                    corrupt.sessionID = corruptSessionID
                case 1:
                    corrupt = try makeFocusTimer(
                        recordID: orderedUUID(172_001 + (corruptionIndex * 10)),
                        sessionID: payloadSessionID,
                        start: base.addingTimeInterval(10),
                        updatedAt: base.addingTimeInterval(10),
                        revision: 1,
                        ownershipSequence: 1,
                        writer: "corrupt-cancelled"
                    )
                    corrupt.status = .cancelled
                    corrupt.terminalAt = corrupt.updatedAt
                    corrupt.sessionID = corruptSessionID
                default:
                    corrupt = try makeFocusTimer(
                        recordID: orderedUUID(172_001 + (corruptionIndex * 10)),
                        sessionID: corruptSessionID,
                        start: base.addingTimeInterval(10),
                        updatedAt: base.addingTimeInterval(10),
                        revision: 1,
                        ownershipSequence: 1,
                        writer: "corrupt-unknown"
                    )
                    corrupt.statusRaw = "future-status-v999"
                }

                let rows = [valid, corrupt]
                let insertionRows = reverseInsertion ? Array(rows.reversed()) : rows
                insertionRows.forEach(context.insert)
                try context.save()

                func fingerprint() throws -> [String] {
                    try context.fetch(FetchDescriptor<SyncedFocusTimer>())
                        .map {
                            [
                                $0.id.uuidString,
                                $0.sessionID.uuidString,
                                $0.statusRaw,
                                $0.terminalAt.map(String.init(describing:)) ?? "nil",
                                $0.payloadData.base64EncodedString()
                            ].joined(separator: "|")
                        }
                        .sorted()
                }
                let original = try fingerprint()
                XCTAssertEqual(original.count, 2)
                XCTAssertEqual(
                    try FocusCloudSyncStore.canonicalActive(context: context)?.sessionID,
                    validSessionID
                )

                let generation = UInt64(
                    710 + (corruptionIndex * 4) + (reverseInsertion ? 1 : 0)
                )
                let first = try await runFocusMaintenance(
                    container: container,
                    generation: generation,
                    maximumSlices: 10
                )
                XCTAssertEqual(first.last?.disposition, .retry)
                XCTAssertEqual(
                    first.last?.failureCategory,
                    "quarantined-focus-timer-payload"
                )
                XCTAssertTrue(first.allSatisfy { $0.audit.saveCount == 0 })
                XCTAssertEqual(try fingerprint(), original)

                let replay = try await runFocusMaintenance(
                    container: container,
                    generation: generation + 100,
                    maximumSlices: 10
                )
                XCTAssertEqual(replay.last?.disposition, .retry)
                XCTAssertTrue(replay.allSatisfy { $0.audit.saveCount == 0 })
                XCTAssertEqual(try fingerprint(), original)
                XCTAssertEqual(
                    try FocusCloudSyncStore.canonicalActive(context: context)?.sessionID,
                    validSessionID
                )
            }
        }
    }

    func testSemanticallyEqualTimerPayloadJSONIsNotQuarantined() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let sessionID = orderedUUID(71_000)
        let recordID = orderedUUID(171_000)
        let instant = Date(timeIntervalSince1970: 1_815_000_000)
        let compacted = try makeFocusTimer(
            recordID: recordID,
            sessionID: sessionID,
            start: instant,
            updatedAt: instant,
            revision: 1,
            ownershipSequence: 1,
            writer: "same-writer"
        )
        let reformatted = try makeFocusTimer(
            recordID: recordID,
            sessionID: sessionID,
            start: instant,
            updatedAt: instant,
            revision: 1,
            ownershipSequence: 1,
            writer: "same-writer"
        )
        let json = try JSONSerialization.jsonObject(with: compacted.payloadData)
        reformatted.payloadData = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        XCTAssertNotEqual(compacted.payloadData, reformatted.payloadData)
        XCTAssertEqual(
            try compacted.decodedPayload(),
            try reformatted.decodedPayload()
        )
        context.insert(reformatted)
        context.insert(compacted)
        try context.save()

        let results = try await runFocusMaintenance(
            container: container,
            generation: 62,
            maximumSlices: 8
        )
        XCTAssertEqual(results.last?.disposition, .completed)
        XCTAssertTrue(results.allSatisfy { $0.disposition != .retry })
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncedFocusTimer>()), 2)
        XCTAssertEqual(
            try FocusCloudSyncStore.canonicalActive(context: context)?.sessionID,
            sessionID
        )
    }

    func testExactReplicaReadPolicyFailsClosedWhenCountChangesDuringFetch() {
        XCTAssertTrue(ExactReplicaReadPolicy.isStable(
            countBefore: 4,
            fetchedCount: 4,
            countAfter: 4,
            maximumSupportedCount: 256
        ))
        XCTAssertFalse(ExactReplicaReadPolicy.isStable(
            countBefore: 4,
            fetchedCount: 4,
            countAfter: 5,
            maximumSupportedCount: 256
        ))
        XCTAssertFalse(ExactReplicaReadPolicy.isStable(
            countBefore: 5,
            fetchedCount: 4,
            countAfter: 5,
            maximumSupportedCount: 256
        ))
        XCTAssertFalse(ExactReplicaReadPolicy.isStable(
            countBefore: 257,
            fetchedCount: 256,
            countAfter: 257,
            maximumSupportedCount: 256
        ))
    }

    func testAggregateRetentionBoundaryDurablyProgressesAcrossFourCopiesFor129IDs() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var logicalIDs: [UUID] = []

        for index in 0 ..< 129 {
            let id = orderedUUID(300_000 + index)
            logicalIDs.append(id)
            for copy in 0 ..< 4 {
                context.insert(makeDatedTimerSession(
                    id: id,
                    syncRecordID: orderedUUID(400_000 + index * 4 + copy),
                    endAt: base.addingTimeInterval(-Double(index * 60))
                ))
            }
        }
        try context.save()

        let results = try await runAggregateMaintenance(
            container: container,
            generation: 901,
            maximumSlices: 80
        )
        XCTAssertEqual(results.last?.disposition, .completed)
        XCTAssertTrue(results.allSatisfy { $0.disposition != .retry })
        XCTAssertTrue(results.contains {
            $0.nextCursor?.phase == 2 && $0.nextCursor?.payload != nil
        }, "the physical keyset and logical candidates must survive a slice boundary")

        let verificationContext = ModelContext(container)
        XCTAssertEqual(
            try verificationContext.fetchCount(FetchDescriptor<StudySession>()),
            129 * 4,
            "retention discovery is a non-destructive read of every physical copy"
        )
        let frontier = AggregatePebblePolicy.accountingFrontier(
            from: try verificationContext.fetch(FetchDescriptor<AggregatePebble>())
        )
        XCTAssertEqual(frontier.representedSessionIDs, Set([logicalIDs[128]]))
        XCTAssertEqual(frontier.summaries.reduce(0) { $0 + $1.pebbleCount }, 1)
        XCTAssertEqual(frontier.summaries.reduce(0) { $0 + $1.grams }, 250)
    }

    func testAggregateVerifierPromotesDeterministicAndExclusiveLegacyV0Leaves() async throws {
        let validContainer = try makeContainer()
        let validContext = validContainer.mainContext
        let memberID = orderedUUID(510_001)
        let session = makeDatedTimerSession(
            id: memberID,
            syncRecordID: orderedUUID(610_001),
            endAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let validLeafID = JarAggregateRequest.deterministicID(
            sourceIDs: [memberID],
            outputLevel: 1
        )
        validContext.insert(session)
        validContext.insert(AggregatePebble(
            id: validLeafID,
            createdAt: .distantPast,
            level: 1,
            pebbleCount: 99,
            grams: 99,
            colorMixJSON: "[]",
            periodStart: .distantPast,
            periodEnd: .distantPast,
            sessionIDs: [memberID],
            projectionValidationVersion: 0
        ))
        try validContext.save()

        let validResults = try await runAggregateMaintenance(
            container: validContainer,
            generation: 902,
            maximumSlices: 30
        )
        XCTAssertEqual(validResults.last?.disposition, .completed)
        let validVerificationContext = ModelContext(validContainer)
        let promoted = try XCTUnwrap(validVerificationContext.fetch(
            FetchDescriptor<AggregatePebble>(
                predicate: #Predicate { $0.id == validLeafID }
            )
        ).first)
        XCTAssertEqual(
            promoted.projectionValidationVersion,
            AggregateProjectionValidation.currentVersion
        )
        XCTAssertEqual(promoted.pebbleCount, 1)
        XCTAssertEqual(promoted.grams, 250)
        XCTAssertEqual(promoted.measuredPebbleCount, 1)
        XCTAssertEqual(promoted.manualPebbleCount, 0)
        XCTAssertEqual(promoted.periodStart, session.endAt)
        XCTAssertEqual(promoted.periodEnd, session.endAt)

        let legacyContainer = try makeContainer()
        let legacyContext = legacyContainer.mainContext
        let legacyMemberID = orderedUUID(510_002)
        legacyContext.insert(makeDatedTimerSession(
            id: legacyMemberID,
            syncRecordID: orderedUUID(610_002),
            endAt: Date(timeIntervalSince1970: 1_700_000_060)
        ))
        let legacyID = orderedUUID(710_002)
        XCTAssertNotEqual(
            legacyID,
            JarAggregateRequest.deterministicID(
                sourceIDs: [legacyMemberID],
                outputLevel: 1
            )
        )
        legacyContext.insert(AggregatePebble(
            id: legacyID,
            level: 1,
            pebbleCount: 1,
            grams: 250,
            colorMixJSON: "[]",
            periodStart: Date(timeIntervalSince1970: 1_700_000_060),
            periodEnd: Date(timeIntervalSince1970: 1_700_000_060),
            sessionIDs: [legacyMemberID],
            projectionValidationVersion: 0
        ))
        try legacyContext.save()

        let legacyResults = try await runAggregateMaintenance(
            container: legacyContainer,
            generation: 903,
            maximumSlices: 30
        )
        XCTAssertEqual(legacyResults.last?.disposition, .completed)
        let legacyVerificationContext = ModelContext(legacyContainer)
        let promotedLegacy = try XCTUnwrap(legacyVerificationContext.fetch(
            FetchDescriptor<AggregatePebble>(
                predicate: #Predicate { $0.id == legacyID }
            )
        ).first)
        XCTAssertEqual(
            promotedLegacy.projectionValidationVersion,
            AggregateProjectionValidation.currentVersion
        )
        XCTAssertNotEqual(
            promotedLegacy.id,
            JarAggregateRequest.deterministicID(
                sourceIDs: promotedLegacy.sessionIDs,
                outputLevel: 1
            )
        )
        XCTAssertFalse(
            AggregatePebblePolicy.accountingFrontier(
                from: try legacyVerificationContext.fetch(
                    FetchDescriptor<AggregatePebble>()
                )
            ).isLowerBound
        )
    }

    func testAggregateVerifierDurablyValidatesTwoMembersWith256CopiesEach() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 1_700_100_000)
        let memberIDs = [orderedUUID(520_001), orderedUUID(520_002)]
        var firstMemberCopies: [StudySession] = []

        for (memberIndex, memberID) in memberIDs.enumerated() {
            for copy in 0 ..< 256 {
                let session = makeDatedTimerSession(
                    id: memberID,
                    syncRecordID: orderedUUID(
                        800_000 + memberIndex * 256 + copy
                    ),
                    endAt: base.addingTimeInterval(Double(memberIndex * 60))
                )
                if memberIndex == 0 { firstMemberCopies.append(session) }
                context.insert(session)
            }
        }
        let leafID = JarAggregateRequest.deterministicID(
            sourceIDs: memberIDs,
            outputLevel: 1
        )
        context.insert(AggregatePebble(
            id: leafID,
            createdAt: .distantPast,
            level: 1,
            pebbleCount: 2,
            grams: 0,
            colorMixJSON: "[]",
            periodStart: .distantPast,
            periodEnd: .distantPast,
            sessionIDs: memberIDs,
            projectionValidationVersion: 0
        ))
        try context.save()

        var cursor: SyncMaintenanceCursor?
        var results: [SyncMaintenanceSliceResult] = []
        for _ in 0 ..< 12 {
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(SyncMaintenanceSliceRequest(
                kind: .aggregates,
                generation: 904,
                cursor: cursor,
                limits: .production
            ))
            assertBudget(result.audit)
            XCTAssertNotEqual(result.disposition, .retry)
            results.append(result)
            cursor = result.nextCursor
            if cursor?.phase == 1, cursor?.payload != nil { break }
        }
        XCTAssertEqual(cursor?.phase, 1)
        XCTAssertNotNil(cursor?.payload)

        // Keep cardinality unchanged while replacing an already-snapshotted
        // physical row with a safer canonical winner. A persisted second-pass
        // prefix would promote the stale 250g/measured value here.
        context.delete(firstMemberCopies[0])
        context.insert(makeDatedTimerSession(
            id: memberIDs[0],
            syncRecordID: orderedUUID(899_999),
            endAt: base.addingTimeInterval(-60),
            source: .timerDemoted,
            minutes: 30
        ))
        try context.save()

        for _ in 0 ..< 40 {
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(SyncMaintenanceSliceRequest(
                kind: .aggregates,
                generation: 904,
                cursor: cursor,
                limits: .production
            ))
            assertBudget(result.audit)
            XCTAssertNotEqual(result.disposition, .retry)
            results.append(result)
            cursor = result.nextCursor
            if result.disposition == .completed { break }
        }
        XCTAssertEqual(results.last?.disposition, .completed)
        XCTAssertTrue(results.allSatisfy { $0.disposition != .retry })
        XCTAssertTrue(results.contains {
            $0.nextCursor?.phase == 1 && $0.nextCursor?.payload != nil
        }, "a dense member group must checkpoint leaf verification, not advance it")

        let verificationContext = ModelContext(container)
        XCTAssertEqual(
            try verificationContext.fetchCount(FetchDescriptor<StudySession>()),
            512
        )
        let verified = try XCTUnwrap(verificationContext.fetch(
            FetchDescriptor<AggregatePebble>(
                predicate: #Predicate { $0.id == leafID }
            )
        ).first)
        XCTAssertEqual(
            verified.projectionValidationVersion,
            AggregateProjectionValidation.currentVersion
        )
        XCTAssertEqual(verified.pebbleCount, 2)
        XCTAssertEqual(verified.grams, 550)
        XCTAssertEqual(verified.measuredPebbleCount, 1)
        XCTAssertEqual(verified.manualPebbleCount, 1)
        XCTAssertEqual(Set(verified.sessionIDs), Set(memberIDs))
    }

    func testDenseLeafThatCannotFitAtomicFinalPassUsesBackoffRetry() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 1_700_150_000)
        let memberIDs = (0 ..< Constants.Jar.aggregateFanIn).map {
            orderedUUID(525_000 + $0)
        }

        for (memberIndex, memberID) in memberIDs.enumerated() {
            for copy in 0 ..< SyncMaintenanceSliceLimits.production
                .maximumRowsPerFetch {
                context.insert(makeDatedTimerSession(
                    id: memberID,
                    syncRecordID: orderedUUID(
                        1_000_000 + memberIndex * 256 + copy
                    ),
                    endAt: base.addingTimeInterval(Double(memberIndex * 60))
                ))
            }
        }
        let leafID = JarAggregateRequest.deterministicID(
            sourceIDs: memberIDs,
            outputLevel: 1
        )
        context.insert(AggregatePebble(
            id: leafID,
            level: 1,
            pebbleCount: memberIDs.count,
            grams: 0,
            colorMixJSON: "[]",
            periodStart: .distantPast,
            periodEnd: .distantPast,
            sessionIDs: memberIDs,
            projectionValidationVersion: 0
        ))
        try context.save()

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var checkpoint = SyncMaintenanceCheckpoint()
        checkpoint.enqueue(.aggregates)
        var retryResult: SyncMaintenanceSliceResult?

        for _ in 0 ..< 20 {
            let request = try XCTUnwrap(checkpoint.nextRequest(
                limits: .production,
                now: now
            ))
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(request)
            assertBudget(result.audit)
            XCTAssertTrue(checkpoint.apply(result, now: now))
            if result.disposition == .retry {
                retryResult = result
                break
            }
            XCTAssertEqual(result.disposition, .moreWork)
        }

        let retry = try XCTUnwrap(retryResult)
        XCTAssertTrue(
            retry.failureCategory?.hasPrefix(
                "dense-aggregate-leaf-final-pass"
            ) == true
        )
        XCTAssertEqual(retry.nextCursor?.phase, 1)
        XCTAssertNotNil(retry.nextCursor?.payload)
        XCTAssertTrue(checkpoint.pendingKinds.contains(.aggregates))
        XCTAssertNil(
            checkpoint.nextRequest(limits: .production, now: now),
            "the foreground drain must not repeat the same 1,024-row read loop"
        )
        XCTAssertEqual(
            checkpoint.nextRequest(
                limits: .production,
                now: now.addingTimeInterval(1)
            )?.kind,
            .aggregates
        )

        let verificationContext = ModelContext(container)
        let unverified = try XCTUnwrap(verificationContext.fetch(
            FetchDescriptor<AggregatePebble>(
                predicate: #Predicate { $0.id == leafID }
            )
        ).first)
        XCTAssertEqual(unverified.projectionValidationVersion, 0)
    }

    func testAggregateVerifierReplacesLateCanonicalLeafAndRederivesAncestor() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 1_700_200_000)
        var sessions: [StudySession] = []

        for index in 0 ..< 100 {
            let minutes = index == 0 ? 120 : 25
            let seconds = minutes * Constants.Timer.secondsPerMinute
            let endAt = base.addingTimeInterval(Double(index * 60))
            let session = StudySession(
                id: orderedUUID(530_000 + index),
                startAt: endAt.addingTimeInterval(-Double(seconds)),
                endAt: endAt,
                seconds: seconds,
                source: .timer,
                pebbleKind: index == 0 ? .prism : .normal,
                grams: minutes * Constants.Mass.gramsPerMinute,
                deviceDayKey: "2026-09-03",
                subjectNameSnapshot: "変更前",
                subjectColorHexSnapshot: Constants.Color.mathematics,
                syncRecordID: orderedUUID(900_000 + index)
            )
            sessions.append(session)
            context.insert(session)
        }

        var leaves: [AggregatePebble] = []
        for start in stride(from: 0, to: sessions.count, by: 10) {
            let members = Array(sessions[start ..< start + 10])
            let request = try XCTUnwrap(JarAggregateRequest(
                createdAt: members.map(\.endAt).max() ?? base,
                pebbles: members.map(PebbleDescriptor.init(session:)),
                innerWidth: 320
            ))
            let leaf = request.makeAggregatePebble()
            leaves.append(leaf)
            context.insert(leaf)
        }
        let parentRequest = try XCTUnwrap(JarAggregateRequest(
            createdAt: leaves.map(\.createdAt).max() ?? base,
            pebbles: leaves.map(PebbleDescriptor.init(aggregate:)),
            innerWidth: 320
        ))
        let parent = parentRequest.makeAggregatePebble()
        leaves.forEach { $0.parentAggregateID = parent.id }
        context.insert(parent)
        try context.save()

        XCTAssertEqual(parent.grams, 25_950)
        XCTAssertEqual(parent.measuredPebbleCount, 100)
        XCTAssertEqual(parent.manualPebbleCount, 0)
        XCTAssertEqual(parent.prismPebbleCount, 1)

        let demotedEnd = base.addingTimeInterval(-10_000)
        let demotedSeconds = 30 * Constants.Timer.secondsPerMinute
        let lateWinner = StudySession(
            id: sessions[0].id,
            startAt: demotedEnd.addingTimeInterval(-Double(demotedSeconds)),
            endAt: demotedEnd,
            seconds: demotedSeconds,
            source: .timerDemoted,
            pebbleKind: .normal,
            grams: 30 * Constants.Mass.gramsPerMinute,
            deviceDayKey: "2026-09-02",
            subjectNameSnapshot: "変更後",
            subjectColorHexSnapshot: Constants.Color.english,
            syncRecordID: orderedUUID(999_999)
        )
        context.insert(lateWinner)
        try context.save()

        let results = try await runAggregateMaintenance(
            container: container,
            generation: 905,
            maximumSlices: 50
        )
        XCTAssertEqual(results.last?.disposition, .completed)
        XCTAssertTrue(results.allSatisfy { $0.disposition != .retry })

        let verificationContext = ModelContext(container)
        XCTAssertEqual(
            try verificationContext.fetchCount(FetchDescriptor<StudySession>()),
            101,
            "a late canonical replacement must not compact either physical source"
        )
        let targetLeafID = leaves[0].id
        let parentID = parent.id
        let repairedLeaf = try XCTUnwrap(verificationContext.fetch(
            FetchDescriptor<AggregatePebble>(
                predicate: #Predicate { $0.id == targetLeafID }
            )
        ).first)
        let repairedParent = try XCTUnwrap(verificationContext.fetch(
            FetchDescriptor<AggregatePebble>(
                predicate: #Predicate { $0.id == parentID }
            )
        ).first)

        XCTAssertEqual(repairedLeaf.pebbleCount, 10)
        XCTAssertEqual(repairedLeaf.grams, 2_550)
        XCTAssertEqual(repairedLeaf.measuredPebbleCount, 9)
        XCTAssertEqual(repairedLeaf.manualPebbleCount, 1)
        XCTAssertEqual(repairedLeaf.prismPebbleCount, 0)
        XCTAssertEqual(repairedLeaf.periodStart, demotedEnd)
        XCTAssertEqual(repairedLeaf.periodEnd, base.addingTimeInterval(9 * 60))
        XCTAssertEqual(repairedLeaf.createdAt, repairedLeaf.periodEnd)
        XCTAssertTrue(repairedLeaf.subjectMix.contains {
            $0.name == "変更後" && $0.pebbleCount == 1
        })

        XCTAssertEqual(repairedParent.pebbleCount, 100)
        XCTAssertEqual(repairedParent.childAggregateCount, 10)
        XCTAssertEqual(repairedParent.grams, 25_050)
        XCTAssertEqual(repairedParent.measuredPebbleCount, 99)
        XCTAssertEqual(repairedParent.manualPebbleCount, 1)
        XCTAssertEqual(repairedParent.prismPebbleCount, 0)
        XCTAssertEqual(repairedParent.periodStart, demotedEnd)
        XCTAssertEqual(repairedParent.periodEnd, base.addingTimeInterval(99 * 60))
        XCTAssertEqual(repairedParent.createdAt, repairedParent.periodEnd)
        XCTAssertEqual(
            repairedLeaf.projectionValidationVersion,
            AggregateProjectionValidation.currentVersion
        )
        XCTAssertEqual(
            repairedParent.projectionValidationVersion,
            AggregateProjectionValidation.currentVersion
        )
    }

    func testAggregateRebuildStartsWhenNewestPhysicalPageContainsDuplicate() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        for index in 1 ... 130 {
            let session = makeSession(
                id: orderedUUID(index),
                grams: 250,
                epochID: nil
            )
            session.syncRecordID = orderedUUID(100_000 + index)
            context.insert(session)
        }
        let newestDuplicate = makeSession(
            id: orderedUUID(130),
            grams: 250,
            epochID: nil
        )
        newestDuplicate.syncRecordID = orderedUUID(200_130)
        context.insert(newestDuplicate)
        try context.save()

        var cursor: SyncMaintenanceCursor?
        var completed = false
        for _ in 0 ..< 40 {
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(SyncMaintenanceSliceRequest(
                kind: .aggregates,
                generation: 90,
                cursor: cursor,
                limits: .production
            ))
            assertBudget(result.audit)
            XCTAssertNotEqual(result.disposition, .retry)
            cursor = result.nextCursor
            if result.disposition == .completed {
                completed = true
                break
            }
        }

        XCTAssertTrue(completed)
        let physical = try context.fetch(FetchDescriptor<StudySession>())
        XCTAssertEqual(physical.count, 131)
        XCTAssertEqual(
            StudySessionSyncPolicy.canonicalSessions(from: physical).count,
            130
        )
        let frontier = AggregatePebblePolicy.accountingFrontier(
            from: try context.fetch(FetchDescriptor<AggregatePebble>())
        )
        XCTAssertEqual(
            frontier.representedSessionIDs,
            Set((1 ... 2).map(orderedUUID)),
            "a duplicate in the full retention page must not suppress the older-history rebuild"
        )
        XCTAssertEqual(
            frontier.summaries.reduce(0) { $0 + $1.pebbleCount },
            2
        )
    }

    func testAggregateRebuildResolvesCopiesAcrossRetentionBoundary() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var normalIDs: [UUID] = []

        for index in 0 ..< 130 {
            let id = orderedUUID(20_000 + index)
            normalIDs.append(id)
            context.insert(makeDatedTimerSession(
                id: id,
                syncRecordID: orderedUUID(120_000 + index),
                endAt: base.addingTimeInterval(-Double(index * 60))
            ))
        }

        let retainedLogicalID = orderedUUID(30_001)
        context.insert(makeDatedTimerSession(
            id: retainedLogicalID,
            syncRecordID: orderedUUID(130_001),
            endAt: base.addingTimeInterval(-50_000)
        ))
        context.insert(makeDatedTimerSession(
            id: retainedLogicalID,
            syncRecordID: orderedUUID(230_001),
            endAt: base.addingTimeInterval(60),
            source: .timerDemoted,
            minutes: 30
        ))

        let projectedLogicalID = orderedUUID(30_002)
        context.insert(makeDatedTimerSession(
            id: projectedLogicalID,
            syncRecordID: orderedUUID(130_002),
            endAt: base.addingTimeInterval(-100_000)
        ))
        context.insert(makeDatedTimerSession(
            id: projectedLogicalID,
            syncRecordID: orderedUUID(230_002),
            endAt: base.addingTimeInterval(-99_900),
            source: .timerDemoted,
            minutes: 30
        ))
        try context.save()

        let results = try await runAggregateMaintenance(
            container: container,
            generation: 91,
            maximumSlices: 80
        )
        XCTAssertEqual(results.last?.disposition, .completed)
        XCTAssertTrue(results.allSatisfy { $0.disposition != .retry })

        let aggregates = try context.fetch(FetchDescriptor<AggregatePebble>())
        let frontier = AggregatePebblePolicy.accountingFrontier(from: aggregates)
        let expectedProjectedIDs = Set(normalIDs.suffix(3) + [projectedLogicalID])
        XCTAssertEqual(frontier.representedSessionIDs, expectedProjectedIDs)
        XCTAssertFalse(frontier.representedSessionIDs.contains(retainedLogicalID))
        XCTAssertEqual(
            frontier.summaries.reduce(0) { $0 + $1.grams },
            1_050
        )
        XCTAssertEqual(
            frontier.summaries.reduce(0) { $0 + $1.measuredPebbleCount },
            3
        )
        XCTAssertEqual(
            frontier.summaries.reduce(0) { $0 + $1.manualPebbleCount },
            1,
            "the aggregate must use the canonical demoted source, not its older timer copy"
        )
    }

    func testAggregateRetentionBoundaryFindsSingletonAfterTwoDenseReplicaGroups() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let firstDenseID = orderedUUID(40_001)
        let secondDenseID = orderedUUID(40_002)

        for index in 0 ..< 128 {
            context.insert(makeDatedTimerSession(
                id: firstDenseID,
                syncRecordID: orderedUUID(140_000 + index),
                endAt: base.addingTimeInterval(-Double(index * 2))
            ))
            context.insert(makeDatedTimerSession(
                id: secondDenseID,
                syncRecordID: orderedUUID(240_000 + index),
                endAt: base.addingTimeInterval(-Double(index * 2 + 1))
            ))
        }
        context.insert(makeDatedTimerSession(
            id: firstDenseID,
            syncRecordID: orderedUUID(340_001),
            endAt: base.addingTimeInterval(-2_000),
            source: .timerDemoted,
            minutes: 30
        ))
        context.insert(makeDatedTimerSession(
            id: secondDenseID,
            syncRecordID: orderedUUID(340_002),
            endAt: base.addingTimeInterval(-2_001),
            source: .timerDemoted,
            minutes: 30
        ))

        let singletonID = orderedUUID(40_003)
        context.insert(makeDatedTimerSession(
            id: singletonID,
            syncRecordID: orderedUUID(340_003),
            endAt: base.addingTimeInterval(-500)
        ))
        var ordinaryIDs: [UUID] = []
        for index in 0 ..< 128 {
            let id = orderedUUID(50_000 + index)
            ordinaryIDs.append(id)
            context.insert(makeDatedTimerSession(
                id: id,
                syncRecordID: orderedUUID(350_000 + index),
                endAt: base.addingTimeInterval(-Double(600 + index))
            ))
        }
        try context.save()

        let results = try await runAggregateMaintenance(
            container: container,
            generation: 92,
            maximumSlices: 80
        )
        XCTAssertEqual(results.last?.disposition, .completed)
        XCTAssertTrue(results.allSatisfy { $0.disposition != .retry })

        let frontier = AggregatePebblePolicy.accountingFrontier(
            from: try context.fetch(FetchDescriptor<AggregatePebble>())
        )
        XCTAssertFalse(frontier.representedSessionIDs.contains(singletonID))
        XCTAssertTrue(frontier.representedSessionIDs.contains(firstDenseID))
        XCTAssertTrue(frontier.representedSessionIDs.contains(secondDenseID))
        XCTAssertTrue(frontier.representedSessionIDs.contains(try XCTUnwrap(ordinaryIDs.last)))
        XCTAssertEqual(frontier.representedSessionIDs.count, 3)
        XCTAssertEqual(
            frontier.summaries.reduce(0) { $0 + $1.measuredPebbleCount },
            1
        )
        XCTAssertEqual(
            frontier.summaries.reduce(0) { $0 + $1.manualPebbleCount },
            2
        )
    }

    func testAggregateRebuildRechecksForegroundOwnershipAndReplaysSavedSlice() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        var sessionsByID: [UUID: StudySession] = [:]
        for index in 1 ... 140 {
            let id = orderedUUID(60_000 + index)
            let session = makeSession(id: id, grams: 250, epochID: nil)
            session.syncRecordID = orderedUUID(160_000 + index)
            sessionsByID[id] = session
            context.insert(session)
        }
        try context.save()

        var cursor: SyncMaintenanceCursor?
        for _ in 0 ..< 4 {
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(SyncMaintenanceSliceRequest(
                kind: .aggregates,
                generation: 93,
                cursor: cursor,
                limits: .production
            ))
            assertBudget(result.audit)
            XCTAssertNotEqual(result.disposition, .retry)
            cursor = result.nextCursor
            if cursor?.phase == 2, cursor?.payload != nil { break }
        }
        XCTAssertEqual(cursor?.phase, 2)
        XCTAssertNotNil(cursor?.payload)

        let foregroundIDs = (1 ... Constants.Jar.aggregateFanIn).map {
            orderedUUID(60_000 + $0)
        }
        let foregroundSessions = try foregroundIDs.map {
            try XCTUnwrap(sessionsByID[$0])
        }
        let foregroundRequest = try XCTUnwrap(JarAggregateRequest(
            pebbles: foregroundSessions.map(PebbleDescriptor.init(session:)),
            innerWidth: 320
        ))
        let foregroundContext = ModelContext(container)
        foregroundContext.insert(foregroundRequest.makeAggregatePebble())
        try foregroundContext.save()

        var completed = false
        var replayedSavedSlice = false
        for _ in 0 ..< 80 {
            let request = SyncMaintenanceSliceRequest(
                kind: .aggregates,
                generation: 93,
                cursor: cursor,
                limits: .production
            )
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(request)
            assertBudget(result.audit)
            XCTAssertNotEqual(result.disposition, .retry)

            if !replayedSavedSlice, result.audit.saveCount == 1 {
                let replay = try await SyncMaintenanceSliceWorker(
                    modelContainer: container
                ).run(request)
                assertBudget(replay.audit)
                XCTAssertNotEqual(replay.disposition, .retry)
                cursor = replay.nextCursor
                replayedSavedSlice = true
                continue
            }

            cursor = result.nextCursor
            if result.disposition == .completed {
                completed = true
                break
            }
        }

        XCTAssertTrue(completed)
        XCTAssertTrue(replayedSavedSlice)
        let aggregates = try context.fetch(FetchDescriptor<AggregatePebble>())
        let frontier = AggregatePebblePolicy.accountingFrontier(from: aggregates)
        XCTAssertTrue(Set(foregroundIDs).isSubset(of: frontier.representedSessionIDs))
        for id in foregroundIDs {
            XCTAssertEqual(
                aggregates.filter { Set($0.sessionIDs).contains(id) && $0.level == 1 }.count,
                1,
                "foreground ownership must not overlap a rebuilt leaf"
            )
        }
        XCTAssertEqual(frontier.representedSessionIDs.count, 12)
    }

    func testAggregateMaintenanceRebuildsEntireHistoryAcrossDurableSlices() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let sessionCount = 620
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var expectedIDs = Set<UUID>()
        var expectedGrams = 0
        var expectedMeasured = 0
        var expectedManual = 0
        var expectedGold = 0
        var expectedPrism = 0
        var aggregatePageBoundarySession: StudySession?

        for index in 1 ... sessionCount {
            let id = orderedUUID(index)
            let source: SessionSource = index.isMultiple(of: 4) ? .manual : .timer
            let seconds: Int
            let grams: Int
            if source == .manual {
                let duration = ManualDuration.allCases[index % ManualDuration.allCases.count]
                seconds = duration.seconds
                grams = duration.grams
            } else {
                let minutes = ((index - 1) % Constants.Timer.customMaximumMinutes) + 1
                seconds = minutes * Constants.Timer.secondsPerMinute
                grams = minutes * Constants.Mass.gramsPerMinute
            }
            let kind: PebbleKind
            if index.isMultiple(of: 17) {
                kind = .prism
                expectedPrism += 1
            } else if index.isMultiple(of: 11) {
                kind = .gold
                expectedGold += 1
            } else {
                kind = .normal
            }
            // A shared timestamp forces the UUID tie-break through both the
            // newest-retention boundary and the older-history keyset.
            let endAt = baseDate
            let session = StudySession(
                id: id,
                startAt: endAt.addingTimeInterval(-TimeInterval(seconds)),
                endAt: endAt,
                seconds: seconds,
                source: source,
                pebbleKind: kind,
                grams: grams,
                deviceDayKey: "2026-09-03",
                subjectNameSnapshot: index.isMultiple(of: 2) ? "数学" : "英語",
                subjectColorHexSnapshot: index.isMultiple(of: 2)
                    ? Constants.Color.mathematics
                    : Constants.Color.english,
                dataEpochID: nil
            )
            if index == 63 { session.syncRecordID = orderedUUID(800_063) }
            context.insert(session)
            if index == 63 { aggregatePageBoundarySession = session }
            expectedIDs.insert(id)
            expectedGrams += grams
            if source.isMeasured {
                expectedMeasured += 1
            } else {
                expectedManual += 1
            }
        }
        let boundarySession = try XCTUnwrap(aggregatePageBoundarySession)
        context.insert(StudySession(
            id: boundarySession.id,
            startAt: boundarySession.startAt,
            endAt: boundarySession.endAt,
            seconds: boundarySession.seconds,
            source: .timerDemoted,
            pebbleKind: .prism,
            grams: boundarySession.grams,
            deviceDayKey: boundarySession.deviceDayKey,
            subjectNameSnapshot: boundarySession.subjectNameSnapshot,
            subjectColorHexSnapshot: boundarySession.subjectColorHexSnapshot,
            dataEpochID: nil,
            syncRecordID: orderedUUID(900_063)
        ))
        expectedMeasured -= 1
        expectedManual += 1
        expectedPrism += 1
        try context.save()

        XCTAssertGreaterThan(sessionCount, HomeProjectionPolicy.looseSessionQueryLimit)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AggregatePebble>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Stratum>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Bedrock>()), 0)

        var cursor: SyncMaintenanceCursor?
        var completed = false
        var passCount = 0
        var replayedStaleCheckpoint = false
        while passCount < 180, !completed {
            let request = SyncMaintenanceSliceRequest(
                kind: .aggregates,
                generation: 9,
                cursor: cursor,
                limits: .production
            )
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(request)
            passCount += 1
            assertBudget(result.audit)
            XCTAssertNotEqual(result.disposition, .retry)

            if !replayedStaleCheckpoint,
               result.nextCursor?.phase == 2,
               result.audit.saveCount == 1 {
                // Simulate a crash after the local aggregate save but before
                // the durable checkpoint accepted this result. Replaying the
                // same request must discover that membership and move forward.
                let saved = try context.fetch(FetchDescriptor<AggregatePebble>())
                let savedMembership = Set(saved.flatMap(\.sessionIDs))
                XCTAssertFalse(savedMembership.isEmpty)
                let replay = try await SyncMaintenanceSliceWorker(
                    modelContainer: container
                ).run(request)
                passCount += 1
                assertBudget(replay.audit)
                XCTAssertNotEqual(replay.disposition, .retry)
                let interim = try context.fetch(FetchDescriptor<AggregatePebble>())
                let interimMembership = interim.flatMap(\.sessionIDs)
                XCTAssertEqual(interimMembership.count, Set(interimMembership).count)
                XCTAssertEqual(
                    Set(interimMembership),
                    savedMembership,
                    "the replay must retain the atomically saved first page"
                )
                cursor = replay.nextCursor
                replayedStaleCheckpoint = true
                continue
            }

            cursor = result.nextCursor
            completed = result.disposition == .completed
        }

        XCTAssertTrue(completed)
        XCTAssertTrue(replayedStaleCheckpoint)
        XCTAssertGreaterThan(passCount, 2, "the rebuild must remain sliced")

        let allSessions = try context.fetch(FetchDescriptor<StudySession>())
        XCTAssertEqual(allSessions.count, sessionCount + 1)
        let logicalSessions = StudySessionSyncPolicy.canonicalSessions(from: allSessions)
        XCTAssertEqual(logicalSessions.count, sessionCount)
        let retainedLooseSessions = Array(logicalSessions.sorted {
            if $0.endAt == $1.endAt { return $0.id.uuidString > $1.id.uuidString }
            return $0.endAt > $1.endAt
        }.prefix(HomeProjectionPolicy.looseSessionLimit))
        let retainedIDs = Set(retainedLooseSessions.map(\.id))
        let expectedProjectedIDs = expectedIDs.subtracting(retainedIDs)
        let retainedRewards = RareRewardCounts.total(
            retainedLooseSessions.map(\.rareRewardCounts)
        )
        let aggregates = try context.fetch(FetchDescriptor<AggregatePebble>())
        let frontier = AggregatePebblePolicy.accountingFrontier(from: aggregates)
        XCTAssertFalse(frontier.isLowerBound)
        XCTAssertFalse(frontier.containsUnknownMembership)
        XCTAssertEqual(frontier.representedSessionIDs, expectedProjectedIDs)
        XCTAssertEqual(
            frontier.summaries.reduce(0) { $0 + $1.pebbleCount },
            expectedProjectedIDs.count
        )
        XCTAssertEqual(
            frontier.summaries.reduce(0) { $0 + $1.grams },
            expectedGrams - retainedLooseSessions.reduce(0) { $0 + $1.grams }
        )
        XCTAssertEqual(
            frontier.summaries.reduce(0) { $0 + $1.measuredPebbleCount },
            expectedMeasured - retainedLooseSessions.filter(\.source.isMeasured).count
        )
        XCTAssertEqual(
            frontier.summaries.reduce(0) { $0 + $1.manualPebbleCount },
            expectedManual - retainedLooseSessions.filter {
                !$0.source.isMeasured
            }.count
        )
        XCTAssertEqual(
            frontier.summaries.reduce(0) { $0 + $1.goldPebbleCount },
            expectedGold - retainedRewards.goldCount
        )
        XCTAssertEqual(
            frontier.summaries.reduce(0) { $0 + $1.prismPebbleCount },
            expectedPrism - retainedRewards.prismCount
        )
        XCTAssertEqual(
            StudySessionSyncPolicy.canonicalSession(
                from: allSessions.filter { $0.id == boundarySession.id }
            )?.pebbleKind,
            .prism,
            "the physical boundary copies remain intact and resolve to the late safer value"
        )
        XCTAssertLessThanOrEqual(
            frontier.summaries.count,
            Constants.Jar.maximumVisibleAggregateRoots
        )

        // Home only materializes its newest bounded query page. Membership in
        // the local leaves removes older candidates while exactly 128 recent
        // completions retain their normal loose-pebble presentation.
        let acceptedIDs = try HomeProjectionPolicy.acceptedRootSummaryIDs(
            roots: frontier.summaries,
            context: context,
            resetMarkers: []
        )
        let acceptedRoots = frontier.summaries.filter {
            acceptedIDs.contains($0.id)
        }
        let newestCandidates = Array(logicalSessions.sorted {
            if $0.endAt == $1.endAt { return $0.id.uuidString > $1.id.uuidString }
            return $0.endAt > $1.endAt
        }.prefix(HomeProjectionPolicy.looseSessionQueryLimit))
        let membership = try HomeProjectionPolicy.localMembershipProjection(
            for: newestCandidates,
            representedAggregateRoots: acceptedRoots,
            context: context,
            resetMarkers: []
        )
        XCTAssertTrue(membership.isCompleteForCandidates)
        let looseSessions = newestCandidates.filter {
            !membership.representedSessionIDs.contains($0.id)
        }
        XCTAssertEqual(Set(looseSessions.map(\.id)), retainedIDs)
        XCTAssertEqual(looseSessions.count, HomeProjectionPolicy.looseSessionLimit)
        let totals = HomeProjectionPolicy.totals(
            roots: acceptedRoots,
            looseSessions: looseSessions
        )
        XCTAssertEqual(totals.pebbleCount, sessionCount)
        XCTAssertEqual(totals.grams, expectedGrams)

        func fingerprint(_ values: [AggregatePebble]) -> [String] {
            values.map {
                [
                    $0.id.uuidString,
                    String($0.level),
                    String($0.pebbleCount),
                    String($0.grams),
                    String($0.measuredPebbleCount),
                    String($0.manualPebbleCount),
                    String($0.goldPebbleCount),
                    String($0.prismPebbleCount),
                    $0.sessionIDsJSON,
                    $0.childAggregateIDsJSON,
                    $0.parentAggregateID?.uuidString ?? "root"
                ].joined(separator: "|")
            }.sorted()
        }
        let firstFingerprint = fingerprint(aggregates)

        // A full new maintenance generation starts from phase zero. It may
        // normalize rows, but must create no second projection or change mass.
        cursor = nil
        completed = false
        for _ in 0 ..< 180 {
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(SyncMaintenanceSliceRequest(
                kind: .aggregates,
                generation: 10,
                cursor: cursor,
                limits: .production
            ))
            assertBudget(result.audit)
            XCTAssertNotEqual(result.disposition, .retry)
            cursor = result.nextCursor
            if result.disposition == .completed {
                completed = true
                break
            }
        }
        XCTAssertTrue(completed)
        let replayedAggregates = try context.fetch(FetchDescriptor<AggregatePebble>())
        XCTAssertEqual(fingerprint(replayedAggregates), firstFingerprint)
        XCTAssertEqual(
            AggregatePebblePolicy.accountingFrontier(from: replayedAggregates)
                .representedSessionIDs,
            expectedProjectedIDs
        )
    }

    func testStaleCompactionIsBoundedAndPreservesUnknownEpoch() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let oldEpoch = UUID()
        let currentEpoch = UUID()
        let unknownEpoch = UUID()
        let unsupportedEpoch = UUID()
        context.insert(ActivityResetMarker(
            epochID: oldEpoch,
            sequence: 1,
            resetAt: Date(timeIntervalSince1970: 1),
            writerDeviceID: "a"
        ))
        context.insert(ActivityResetMarker(
            epochID: currentEpoch,
            sequence: 2,
            resetAt: Date(timeIntervalSince1970: 2),
            writerDeviceID: "b"
        ))
        context.insert(ActivityResetMarker(
            epochID: unsupportedEpoch,
            sequence: ActivityResetPolicy.maximumSupportedSequence + 1,
            resetAt: Date.now.addingTimeInterval(60 * 60 * 24 * 365 * 100),
            writerDeviceID: "corrupt"
        ))
        for _ in 0 ..< 300 {
            context.insert(makeSession(id: UUID(), grams: 1, epochID: oldEpoch))
        }
        context.insert(makeSession(id: UUID(), grams: 2, epochID: currentEpoch))
        context.insert(makeSession(id: UUID(), grams: 3, epochID: unknownEpoch))
        context.insert(makeSession(id: UUID(), grams: 5, epochID: unsupportedEpoch))
        context.insert(makeSession(id: UUID(), grams: 4, epochID: nil))
        try context.save()

        var cursor: SyncMaintenanceCursor?
        var completed = false
        for _ in 0 ..< 16 {
            let request = SyncMaintenanceSliceRequest(
                kind: .staleEpochCompaction,
                generation: 3,
                cursor: cursor,
                limits: .production
            )
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(request)
            assertBudget(result.audit)
            XCTAssertNotEqual(result.disposition, .retry)
            cursor = result.nextCursor
            if result.disposition == .completed {
                completed = true
                break
            }
        }

        XCTAssertTrue(completed)
        let sessions = try context.fetch(FetchDescriptor<StudySession>())
        XCTAssertEqual(sessions.filter { $0.dataEpochID == oldEpoch }.count, 0)
        XCTAssertEqual(sessions.filter { $0.dataEpochID == nil }.count, 0)
        XCTAssertEqual(sessions.filter { $0.dataEpochID == currentEpoch }.count, 1)
        XCTAssertEqual(sessions.filter { $0.dataEpochID == unknownEpoch }.count, 1)
        XCTAssertEqual(
            sessions.filter { $0.dataEpochID == unsupportedEpoch }.count,
            1,
            "unsupported epochs remain quarantined instead of being compacted"
        )
    }

    private func assertBudget(
        _ audit: SyncMaintenanceFetchAudit,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            audit.maximumRowsReturnedByAnyFetch,
            256,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            audit.totalRowsAccessed,
            1_024,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(audit.saveCount, 1, file: file, line: line)
    }

    private func runAggregateMaintenance(
        container: ModelContainer,
        generation: UInt64,
        maximumSlices: Int
    ) async throws -> [SyncMaintenanceSliceResult] {
        var cursor: SyncMaintenanceCursor?
        var results: [SyncMaintenanceSliceResult] = []
        for _ in 0 ..< maximumSlices {
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(SyncMaintenanceSliceRequest(
                kind: .aggregates,
                generation: generation,
                cursor: cursor,
                limits: .production
            ))
            assertBudget(result.audit)
            results.append(result)
            guard result.disposition == .moreWork else { return results }
            cursor = result.nextCursor
        }
        XCTFail("aggregate maintenance exceeded \(maximumSlices) bounded slices")
        return results
    }

    private func runFocusMaintenance(
        container: ModelContainer,
        generation: UInt64,
        maximumSlices: Int
    ) async throws -> [SyncMaintenanceSliceResult] {
        var cursor: SyncMaintenanceCursor?
        var results: [SyncMaintenanceSliceResult] = []
        for _ in 0 ..< maximumSlices {
            let result = try await SyncMaintenanceSliceWorker(
                modelContainer: container
            ).run(SyncMaintenanceSliceRequest(
                kind: .focusFairness,
                generation: generation,
                cursor: cursor,
                limits: .production
            ))
            assertBudget(result.audit)
            results.append(result)
            guard result.disposition == .moreWork else { return results }
            cursor = result.nextCursor
        }
        XCTFail("focus maintenance exceeded \(maximumSlices) bounded slices")
        return results
    }

    private func makeFocusTimer(
        recordID: UUID,
        sessionID: UUID,
        start: Date,
        updatedAt: Date,
        revision: Int,
        ownershipSequence: Int,
        writer: String,
        subjectName: String = "集中"
    ) throws -> SyncedFocusTimer {
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: sessionID)
        let payload = try FocusCloudPayload(envelope: FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(
                id: orderedUUID(900_000),
                name: subjectName,
                colorHex: Constants.Color.mathematics
            ),
            clockAnchor: nil,
            pendingCompletion: nil,
            savedAt: updatedAt
        ))
        return try SyncedFocusTimer(
            id: recordID,
            sessionID: sessionID,
            status: .running,
            payload: payload,
            updatedAt: updatedAt,
            revision: revision,
            ownershipSequence: ownershipSequence,
            writerDeviceID: writer
        )
    }

    private func makePendingFocusTimer(
        recordID: UUID,
        sessionID: UUID,
        start: Date,
        writer: String
    ) throws -> SyncedFocusTimer {
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: start, sessionID: sessionID)
        let completedAt = start.addingTimeInterval(1_500)
        guard case let .focusCompleted(completion)? = engine.advance(at: completedAt) else {
            throw FocusCloudSyncError.invalidPayload
        }
        let payload = try FocusCloudPayload(envelope: FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(
                id: orderedUUID(900_001),
                name: "集中",
                colorHex: Constants.Color.english
            ),
            clockAnchor: nil,
            pendingCompletion: completion,
            savedAt: completedAt
        ))
        return try SyncedFocusTimer(
            id: recordID,
            sessionID: sessionID,
            status: .completionPending,
            payload: payload,
            updatedAt: completedAt,
            revision: 1,
            ownershipSequence: 1,
            writerDeviceID: writer
        )
    }

    private func makeSession(
        id: UUID,
        grams: Int,
        kind: PebbleKind = .normal,
        epochID: UUID?
    ) -> StudySession {
        let boundedGrams = min(
            StudySessionIntegrityPolicy.maximumGrams,
            max(Constants.Mass.gramsPerMinute,
                grams / Constants.Mass.gramsPerMinute
                    * Constants.Mass.gramsPerMinute)
        )
        let seconds = boundedGrams / Constants.Mass.gramsPerMinute
            * Constants.Timer.secondsPerMinute
        let endAt = Date(timeIntervalSince1970: 20)
        return StudySession(
            id: id,
            startAt: endAt.addingTimeInterval(-TimeInterval(seconds)),
            endAt: endAt,
            seconds: seconds,
            source: .timer,
            pebbleKind: kind,
            grams: boundedGrams,
            deviceDayKey: "2026-09-03",
            dataEpochID: epochID
        )
    }

    private func makeDatedTimerSession(
        id: UUID,
        syncRecordID: UUID,
        endAt: Date,
        source: SessionSource = .timer,
        minutes: Int = 25
    ) -> StudySession {
        let seconds = minutes * Constants.Timer.secondsPerMinute
        return StudySession(
            id: id,
            startAt: endAt.addingTimeInterval(-TimeInterval(seconds)),
            endAt: endAt,
            seconds: seconds,
            source: source,
            grams: minutes * Constants.Mass.gramsPerMinute,
            deviceDayKey: "2026-09-03",
            dataEpochID: nil,
            syncRecordID: syncRecordID
        )
    }

    private func sessionFingerprint(_ value: StudySession) -> String {
        [
            value.id.uuidString,
            value.syncRecordID.uuidString,
            value.startAt.timeIntervalSinceReferenceDate.description,
            value.endAt.timeIntervalSinceReferenceDate.description,
            String(value.seconds),
            value.source.rawValue,
            value.pebbleKind.rawValue,
            String(value.grams),
            value.deviceDayKey,
            value.rareRewardRuleVersion.map(String.init) ?? "nil",
            value.rareRewardParticipated.map { String($0) } ?? "nil",
            value.rareRewardCreditedGrams.map(String.init) ?? "nil",
            value.rareRewardOutcomesRawValue ?? "nil"
        ].joined(separator: "|")
    }

    private func subjectFingerprint(_ value: Subject) -> String {
        [
            value.id.uuidString,
            value.syncRecordID.uuidString,
            String(value.contentRevision),
            value.contentMutationID.uuidString,
            value.name,
            value.colorHex,
            String(value.sortOrder),
            String(value.isArchived),
            value.deletedAt?.timeIntervalSinceReferenceDate.description ?? "nil"
        ].joined(separator: "|")
    }

    private func achievementFingerprint(_ value: AchievementStone) -> String {
        [
            value.id.uuidString,
            value.syncRecordID.uuidString,
            String(value.revision),
            value.kind.rawValue,
            value.note,
            value.deletedAt?.timeIntervalSinceReferenceDate.description ?? "nil",
            String(value.deletionRevision),
            value.deletionMutationID?.uuidString ?? "nil",
            value.restoredDeletionMutationID?.uuidString ?? "nil",
            value.updatedAt.timeIntervalSinceReferenceDate.description
        ].joined(separator: "|")
    }

    private func prefsFingerprint(_ value: Prefs) -> String {
        var fields: [String] = [
            value.id.uuidString,
            value.syncRecordID.uuidString,
            value.settingsWriterID,
            String(value.soundOn),
            String(value.soundRevision),
            value.soundMutationID?.uuidString ?? "nil",
            String(value.hapticsOn),
            String(value.hapticsRevision),
            value.hapticsMutationID?.uuidString ?? "nil"
        ]
        fields.append(contentsOf: [
            value.timerCompletionSoundRawValue,
            String(value.timerCompletionSoundRevision),
            value.timerCompletionSoundMutationID?.uuidString ?? "nil",
            value.timerCompletionHapticRawValue,
            String(value.timerCompletionHapticRevision),
            value.timerCompletionHapticMutationID?.uuidString ?? "nil"
        ])
        fields.append(contentsOf: [
            value.rareRewardModeRawValue,
            String(value.rareRewardRevision),
            value.rareRewardMutationID?.uuidString ?? "nil",
            String(value.reminderEnabled),
            String(value.reminderEnabledRevision),
            value.reminderEnabledMutationID?.uuidString ?? "nil"
        ])
        fields.append(contentsOf: [
            String(value.reminderHour),
            String(value.reminderMinute),
            String(value.reminderTimeRevision),
            value.reminderTimeMutationID?.uuidString ?? "nil",
            String(value.shareIncludesManual),
            String(value.shareIncludesManualRevision),
            value.shareIncludesManualMutationID?.uuidString ?? "nil",
            String(value.showsThemeNameExternally),
            String(value.externalThemeRevision),
            value.externalThemeMutationID?.uuidString ?? "nil"
        ])
        fields.append(contentsOf: [
            String(value.keepScreenAwake),
            String(value.keepScreenAwakeRevision),
            value.keepScreenAwakeMutationID?.uuidString ?? "nil",
            String(value.preferredFocusMinutes),
            String(value.preferredFocusMinutesRevision),
            value.preferredFocusMinutesMutationID?.uuidString ?? "nil",
            value.timerDisplayModeRawValue,
            String(value.timerDisplayModeRevision),
            value.timerDisplayModeMutationID?.uuidString ?? "nil",
            value.usagePurposeRawValue,
            String(value.usagePurposeRevision),
            value.usagePurposeMutationID?.uuidString ?? "nil"
        ])
        return fields.joined(separator: "|")
    }

    private func waitForPreviewSleep(
        _ gate: TimerCompletionPreviewSleepGate,
        count: Int,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await gate.pendingCount == count { return }
            await Task.yield()
        }
        XCTFail(
            "Timed out waiting for \(count) pending preview sleep(s)",
            line: line
        )
    }

    private func waitForPreviewState(
        _ controller: TimerCompletionPreviewController,
        _ state: TimerCompletionPreviewState,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if controller.state == state { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for preview state \(state)", line: line)
    }

    private func waitForCompletionAlertSleep(
        _ gate: TimerCompletionAlertSleepGate,
        count: Int,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await gate.pendingCount == count { return }
            await Task.yield()
        }
        XCTFail(
            "Timed out waiting for \(count) completion-alert sleep(s)",
            line: line
        )
    }

    private func waitForCompletionAlertPlayback(
        _ spy: TimerCompletionAlertPlaybackSpy,
        count: Int,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if spy.configurations.count == count { return }
            await Task.yield()
        }
        XCTFail(
            "Timed out waiting for \(count) completion-alert playback(s)",
            line: line
        )
    }

    private func claimFingerprint(_ value: FocusTimerDeviceClaim) -> String {
        [
            value.id.uuidString,
            value.syncRecordID.uuidString,
            value.sessionID.uuidString,
            value.deviceID,
            String(value.sequence),
            value.claimedAt.timeIntervalSinceReferenceDate.description,
            value.releasedAt?.timeIntervalSinceReferenceDate.description ?? "nil",
            value.dataEpochID?.uuidString ?? "nil"
        ].joined(separator: "|")
    }

    private func orderedUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(
            format: "00000000-0000-0000-0000-%012llX",
            Int64(value)
        ))!
    }
}

private actor TimerCompletionPreviewSleepGate {
    private var continuations: [CheckedContinuation<Void, Error>] = []

    var pendingCount: Int { continuations.count }

    func sleep() async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor TimerCompletionAlertSleepGate {
    private var continuations: [CheckedContinuation<Void, Error>] = []

    var pendingCount: Int { continuations.count }

    func sleep() async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

@MainActor
private final class TimerCompletionPreviewPlaybackSpy {
    var configurations: [TimerCompletionPreviewConfiguration] = []
}

@MainActor
private final class TimerCompletionAlertPlaybackSpy {
    var configurations: [TimerCompletionAlertConfiguration] = []
    var stopCount = 0
    var applicationIsActive = true
}
