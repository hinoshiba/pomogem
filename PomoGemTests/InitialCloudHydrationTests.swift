import SwiftData
import XCTest
@testable import PomoGem

/// Deterministically replays delayed import into the production persistence
/// policy. No network, reset action, or real account store is used. Activity is
/// created only after the production preflight observes the imported epoch.
@MainActor
final class InitialCloudHydrationTests: XCTestCase {
    func testNewManualSessionWaitsForFirstResetMarkerImportAndSurvivesMaintenance() async throws {
        try await verifyManualSessionSurvivesDelayedHistory(preloadedEpoch: nil)
    }

    func testOldContextWithPartiallyImportedHistoryWaitsBeforeNewManualSession() async throws {
        try await verifyManualSessionSurvivesDelayedHistory(preloadedEpoch: UUID())
    }

    func testNewTimerWaitsForResetHistoryAndSurvivesMaintenance() async throws {
        let container = try await containerAfterVerifiedHydration(preloadedEpoch: nil)
        let context = container.mainContext
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionID = UUID()
        let initiallyKnownEpoch = try ActivityResetStore.currentEpochID(context: context)
        XCTAssertEqual(initiallyKnownEpoch, remoteMarker.epochID)
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: startedAt, sessionID: sessionID)

        // This is the actual runtime admission API called when focus state is
        // persisted. It checks only the reset markers available in this context.
        let admitted = try FocusCloudSyncStore.upsert(
            envelope: FocusRecoveryEnvelope(
                engine: engine,
                subject: FocusSubjectSnapshot(id: UUID(), name: "PomoGemAudit-Hydration", colorHex: "#888888"),
                clockAnchor: nil,
                pendingCompletion: nil,
                savedAt: startedAt,
                dataEpochID: initiallyKnownEpoch
            ),
            status: .running,
            context: context,
            deviceID: "hydrating-device",
            claimIfUnowned: true,
            now: startedAt
        )
        try context.save()
        XCTAssertEqual(admitted.status, .running)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncedFocusTimer>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FocusTimerDeviceClaim>()), 1)

        let hydrated = try ActivityResetStore.snapshots(context: context)
        XCTAssertEqual(
            ActivityResetPolicy.state(of: initiallyKnownEpoch, markers: hydrated),
            .current,
            "An accepted new timer must not be invalidated by a reset that predates its start"
        )
        // The shipped compaction implementation is also exercised, rather than
        // inferring physical deletion solely from the visibility policy.
        try SeedData.bootstrap(context: context)
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<SyncedFocusTimer>()).contains { $0.sessionID == sessionID },
            "Delayed preexisting reset history must not delete an accepted timer"
        )
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<FocusTimerDeviceClaim>()).contains { $0.sessionID == sessionID },
            "Delayed preexisting reset history must not delete the new timer's claim"
        )
    }

    private func verifyManualSessionSurvivesDelayedHistory(preloadedEpoch: UUID?) async throws {
        let container = try await containerAfterVerifiedHydration(preloadedEpoch: preloadedEpoch)
        let context = container.mainContext
        let recordedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let subject = Subject(name: "PomoGemAudit-Hydration", colorHex: "#888888", sortOrder: 0)
        let prefs = Prefs(manualDayKey: FairnessPolicy.deviceDayKey(for: recordedAt), manualUsedToday: 0)
        context.insert(subject)
        context.insert(prefs)
        try context.save()

        // HomeView.addManualEntry is private SwiftUI orchestration. Replay its
        // actual production collaborators and transaction, without substituting
        // a custom admission rule or calling the newly disabled reset action.
        let visibleMarkers = try ActivityResetStore.snapshots(context: context)
        let epochAtAcceptance = ActivityResetPolicy.currentEpochID(from: visibleMarkers)
        XCTAssertEqual(epochAtAcceptance, remoteMarker.epochID)
        let decision = FairnessPolicy.consumeManualEntry(
            state: ManualCounterState(dayKey: prefs.manualDayKey, usedToday: prefs.manualUsedToday),
            at: recordedAt
        )
        XCTAssertTrue(decision.isAllowed)
        let writer = try PrefsSyncPolicy.ensureWriterRow(
            context: context,
            writerID: "hydrating-device",
            currentEpochID: epochAtAcceptance
        )
        writer.manualDayKey = decision.state.dayKey
        writer.manualUsedToday = decision.state.usedToday
        let duration = ManualDuration.thirtyMinutes
        let session = StudySession(
            subject: subject,
            startAt: recordedAt.addingTimeInterval(-TimeInterval(duration.seconds)),
            endAt: recordedAt,
            seconds: duration.seconds,
            source: .manual,
            grams: duration.grams,
            deviceDayKey: FairnessPolicy.deviceDayKey(for: recordedAt),
            dataEpochID: epochAtAcceptance
        )
        let sessionID = session.id
        context.insert(session)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StudySession>()), 1)
        XCTAssertTrue(ActivityResetPolicy.isCurrent(epochAtAcceptance, markers: visibleMarkers))
        XCTAssertEqual(writer.manualUsedToday, 1)

        let hydratedMarkers = try ActivityResetStore.snapshots(context: context)
        XCTAssertTrue(
            ActivityResetPolicy.isCurrent(epochAtAcceptance, markers: hydratedMarkers),
            "A successfully saved new manual session must not disappear when older reset history imports"
        )
        try SeedData.bootstrap(context: context)
        XCTAssertTrue(
            try context.fetch(FetchDescriptor<StudySession>()).contains { $0.id == sessionID },
            "Delayed preexisting reset history must not physically delete the newly saved session"
        )
    }

    func testImportTimeoutDoesNotCreateActivityOrPreferences() async throws {
        let container = try makeContainer()
        let remote = remoteMarker
        let client = CloudActivityHistoryClient(verifyAccount: { _ in }, readMarkers: { [remote] })
        do {
            try await CloudActivityHistoryPreflight(client: client, timeout: 0.05, pollInterval: 0.01)
                .run(context: container.mainContext, expectedBinding: binding, validateMount: {})
            XCTFail("Unimported history must not permit new activity")
        } catch { XCTAssertEqual(error as? CloudActivityHistoryPreflightError, .timedOut) }
        try assertNoActivity(in: container.mainContext)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Prefs>()), 0)
        XCTAssertFalse(container.mainContext.hasChanges)
    }

    private func containerAfterVerifiedHydration(preloadedEpoch: UUID?) async throws -> ModelContainer {
        let container = try makeContainer()
        let oldContext = container.mainContext
        if let preloadedEpoch {
            oldContext.insert(ActivityResetMarker(epochID: preloadedEpoch, sequence: 2,
                                                  resetAt: remoteMarker.resetAt.addingTimeInterval(-604_800),
                                                  writerDeviceID: "older-installation"))
            try oldContext.save()
        }
        // Register the old view of history before a separate importer commits
        // the server marker. The production preflight must use fresh readers.
        XCTAssertEqual(try ActivityResetStore.currentEpochID(context: oldContext), preloadedEpoch)
        let remote = remoteMarker
        let pending = expectation(description: "preflight waits for history")
        let finished = expectation(description: "preflight admits imported history")
        let state = HydrationAdmissionState()
        let client = CloudActivityHistoryClient(verifyAccount: { _ in }, readMarkers: { [remote] })
        let preflight = CloudActivityHistoryPreflight(client: client, timeout: 2, pollInterval: 0.01)
        let task = Task { @MainActor in
            defer { state.finished = true; finished.fulfill() }
            try await preflight.run(context: oldContext, expectedBinding: binding, validateMount: {
                state.checks += 1
                if state.checks == 5 { pending.fulfill() }
            })
        }
        await fulfillment(of: [pending], timeout: 1)
        XCTAssertFalse(state.finished, "A missing or lower local epoch cannot authorize writers")
        try assertNoActivity(in: oldContext)
        XCTAssertEqual(try oldContext.fetchCount(FetchDescriptor<Prefs>()), 0)
        let importer = ModelContext(container)
        importer.insert(ActivityResetMarker(id: remote.id, epochID: remote.epochID,
                                            sequence: remote.sequence, resetAt: remote.resetAt,
                                            writerDeviceID: remote.writerDeviceID))
        try importer.save()
        await fulfillment(of: [finished], timeout: 3)
        try await task.value
        XCTAssertEqual(try ActivityResetStore.currentEpochID(context: oldContext), remote.epochID)
        return container
    }

    private func assertNoActivity(in context: ModelContext) throws {
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StudySession>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<AchievementStone>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SyncedFocusTimer>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<FocusTimerDeviceClaim>()), 0)
    }

    private var remoteMarker: ActivityResetSnapshot {
        ActivityResetSnapshot(id: UUID(uuidString: "10000000-0000-0000-0000-000000000009")!,
                              epochID: UUID(uuidString: "20000000-0000-0000-0000-000000000009")!,
                              sequence: 9, resetAt: Date(timeIntervalSince1970: 1_799_913_600),
                              writerDeviceID: "previous-installation")
    }

    private var binding: ActiveAccountLocalBinding {
        ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: String(repeating: "a", count: 64))!
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Subject.self, StudySession.self, AchievementStone.self,
            AggregatePebble.self, Stratum.self, Bedrock.self, GachaState.self,
            Prefs.self, ActivityResetMarker.self, SyncedFocusTimer.self,
            FocusTimerDeviceClaim.self, RareRewardPendingCommit.self, RareRewardLedgerCursor.self
        ])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(
            "InitialCloudHydrationTests", schema: schema,
            isStoredInMemoryOnly: true, cloudKitDatabase: .none
        )])
    }
}

@MainActor
private final class HydrationAdmissionState {
    var checks = 0
    var finished = false
}
