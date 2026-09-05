import CloudKit
import SwiftData
import XCTest
@testable import Tsumiben

@MainActor
final class CompleteDataDeletionTests: XCTestCase {
    func testExperimentalCompleteDeletionIsNotExposedInVersionOne() {
        XCTAssertFalse(CompleteDataDeletionReleasePolicy.isEnabled)
    }
    private func makeContainer() throws -> ModelContainer {
        let schema = PersistenceStoreTopology.shippingSchema
        let configuration = ModelConfiguration(
            "CompleteDataDeletionTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func testModelStoreDeletesAndVerifiesEveryShippingModel() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let generationID = UUID()
        let subject = Subject(
            name: "削除対象",
            colorHex: "#123456",
            sortOrder: 0,
            createdAt: date
        )
        context.insert(subject)
        context.insert(StudySession(
            subject: subject,
            startAt: date,
            endAt: date.addingTimeInterval(1_500),
            seconds: 1_500,
            source: .timer,
            deviceDayKey: "2027-01-15",
            dataEpochID: generationID
        ))
        context.insert(AchievementStone(
            subject: subject,
            kind: .workMilestone,
            note: "private note",
            achievedAt: date,
            createdAt: date,
            dataEpochID: generationID
        ))
        context.insert(AggregatePebble(
            level: 1,
            pebbleCount: 1,
            grams: 250,
            colorMixJSON: "[]",
            periodStart: date,
            periodEnd: date,
            dataEpochID: generationID
        ))
        context.insert(Stratum(
            pebbleCount: 1,
            heightPt: 1,
            colorMixJSON: "[]",
            monthLabel: "2027-01",
            dataEpochID: generationID
        ))
        context.insert(Bedrock(hours: 40, importedAt: date, dataEpochID: generationID))
        context.insert(GachaState(dataEpochID: generationID))
        context.insert(Prefs(activityEpochID: generationID))
        context.insert(ActivityResetMarker(
            epochID: generationID,
            sequence: 1,
            resetAt: date,
            writerDeviceID: "device"
        ))

        let timerSessionID = UUID()
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(
            isPro: false,
            now: date,
            sessionID: timerSessionID
        )
        let envelope = FocusRecoveryEnvelope(
            engine: engine,
            subject: FocusSubjectSnapshot(
                id: subject.id,
                name: subject.name,
                colorHex: subject.colorHex
            ),
            clockAnchor: nil,
            pendingCompletion: nil,
            savedAt: date,
            dataEpochID: generationID
        )
        context.insert(try SyncedFocusTimer(
            sessionID: timerSessionID,
            status: .running,
            payload: FocusCloudPayload(envelope: envelope),
            updatedAt: date,
            writerDeviceID: "device"
        ))
        context.insert(FocusTimerDeviceClaim(
            sessionID: timerSessionID,
            deviceID: "device",
            sequence: 1,
            claimedAt: date,
            dataEpochID: generationID
        ))

        try context.save()

        let store = CompleteDataDeletionModelStore(modelContainer: container)
        let before = try await store.counts()
        XCTAssertEqual(before.total, 11)

        let remaining = try await store.deleteAllModels()
        XCTAssertEqual(remaining, .zero)
        let verifiedRemaining = try await store.counts()
        XCTAssertEqual(verifiedRemaining, .zero)
    }

    func testModelStoreDeletesCloudAndLocalProjectionConfigurations() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "CompleteDataDeletionSplit-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultsDomain = "CompleteDataDeletionSplit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsDomain))
        defer {
            defaults.removePersistentDomain(forName: defaultsDomain)
            try? fileManager.removeItem(at: root)
        }

        let container = try PersistenceStoreTopology.makeTestingSplitContainer(
            cloudStoreURL: root.appendingPathComponent("Cloud.store"),
            localStoreURL: root.appendingPathComponent("Local.store"),
            defaults: defaults,
            migrationIdentifier: "complete-deletion"
        )
        let context = container.mainContext
        context.insert(Subject(
            name: "同期対象",
            colorHex: "#123456",
            sortOrder: 0
        ))
        context.insert(AggregatePebble(
            level: 1,
            pebbleCount: 1,
            grams: 250,
            colorMixJSON: "[]",
            periodStart: .now,
            periodEnd: .now
        ))
        try context.save()

        let store = CompleteDataDeletionModelStore(modelContainer: container)
        let before = try await store.counts()
        XCTAssertEqual(before.cloudStoreTotal, 1)
        XCTAssertEqual(before.localProjectionStoreTotal, 1)

        let deleted = try await store.deleteAllModels()
        let verified = try await store.counts()
        XCTAssertEqual(deleted, .zero)
        XCTAssertEqual(verified, .zero)
    }

    func testCoordinatorKeepsPendingMarkerAndResumesAfterCloudFailure() async throws {
        let state = MemoryDeletionStateStore()
        let remote = StubRemoteStore(failZoneDeletionCount: 1)
        let local = StubLocalModelStore()
        let device = StubDeviceState()
        let transactionID = UUID()
        let generationID = UUID()
        let idSource = LockedIDSource([transactionID, generationID])
        let instant = Date(timeIntervalSince1970: 1_810_000_000)
        let coordinator = CompleteDataDeletionCoordinator(
            stateStore: state,
            remoteStore: remote,
            localModelStore: local,
            deviceState: device,
            now: { instant },
            makeID: { idSource.next() }
        )

        do {
            _ = try await coordinator.deleteAllData()
            XCTFail("CloudKit failure must not be reported as success")
        } catch {
            XCTAssertNotNil(error as? CompleteDataDeletionError)
        }

        let failedMarker = await state.loadPendingMarker()
        XCTAssertEqual(failedMarker?.transactionID, transactionID)
        XCTAssertEqual(failedMarker?.requestedGenerationID, generationID)
        XCTAssertEqual(failedMarker?.phase, .deletePrivateCloudData)
        XCTAssertEqual(failedMarker?.failureCount, 1)
        let failedReceipt = await state.loadGenerationReceipt()
        XCTAssertNil(failedReceipt)

        let result = try await coordinator.deleteAllData()
        XCTAssertEqual(result.fence.generationID, generationID)
        XCTAssertEqual(result.fence.state, .committed)
        XCTAssertEqual(result.deletedCloudZoneCount, 2)
        XCTAssertTrue(result.requiresRelaunch)
        let completedMarker = await state.loadPendingMarker()
        let completedReceipt = await state.loadGenerationReceipt()
        XCTAssertNil(completedMarker)
        XCTAssertEqual(completedReceipt?.generationID, generationID)

        let localDeleteCalls = await local.deleteCalls()
        let establishedTransactions = await remote.establishedTransactions()
        let remoteDeleteCalls = await remote.zoneDeleteCalls()
        XCTAssertEqual(localDeleteCalls, 1)
        XCTAssertEqual(establishedTransactions, [transactionID])
        XCTAssertEqual(remoteDeleteCalls, 2)
        XCTAssertEqual(device.clearCalls, 1)
        XCTAssertEqual(device.quiesceCalls, 2)
    }

    func testPreparationStopsAfterFenceBeforeMountedStoreDeletion() async throws {
        let state = MemoryDeletionStateStore()
        let remote = StubRemoteStore(failZoneDeletionCount: 0)
        let local = StubLocalModelStore()
        let device = StubDeviceState()
        let coordinator = CompleteDataDeletionCoordinator(
            stateStore: state,
            remoteStore: remote,
            localModelStore: local,
            deviceState: device
        )

        let prepared = try await coordinator.prepareForPersistenceUnmount()
        let deleteCallsBeforeUnmount = await local.deleteCalls()
        let zoneDeleteCallsBeforeUnmount = await remote.zoneDeleteCalls()
        let persistedPreparedMarker = await state.loadPendingMarker()

        XCTAssertEqual(prepared.phase, .quiesceApplication)
        XCTAssertEqual(prepared.fence?.state, .pending)
        XCTAssertEqual(deleteCallsBeforeUnmount, 0)
        XCTAssertEqual(zoneDeleteCallsBeforeUnmount, 0)
        XCTAssertEqual(device.clearCalls, 0)
        XCTAssertEqual(persistedPreparedMarker, prepared)

        let result = try await coordinator.deleteAllData()
        let deleteCallsAfterResume = await local.deleteCalls()
        let zoneDeleteCallsAfterResume = await remote.zoneDeleteCalls()
        XCTAssertEqual(result.fence.state, .committed)
        XCTAssertEqual(deleteCallsAfterResume, 1)
        XCTAssertEqual(zoneDeleteCallsAfterResume, 1)
    }

    func testCoordinatorDoesNotSucceedUntilPendingJournalIsRemoved() async throws {
        let state = MemoryDeletionStateStore(failMarkerRemovalCount: 1)
        let remote = StubRemoteStore(failZoneDeletionCount: 0)
        let coordinator = CompleteDataDeletionCoordinator(
            stateStore: state,
            remoteStore: remote,
            localModelStore: StubLocalModelStore(),
            deviceState: StubDeviceState()
        )

        do {
            _ = try await coordinator.deleteAllData()
            XCTFail("A retained pending journal must not be called success")
        } catch {
            let retainedMarker = await state.loadPendingMarker()
            XCTAssertNotNil(retainedMarker)
        }

        let result = try await coordinator.deleteAllData()
        XCTAssertEqual(result.fence.state, .committed)
        let completedMarker = await state.loadPendingMarker()
        XCTAssertNil(completedMarker)
    }

    func testLaunchAndWriteGatesRejectAnOfflineOldGeneration() {
        let oldFence = fence(sequence: 1, state: .committed)
        let currentFence = fence(sequence: 2, state: .committed)
        let oldReceipt = CompleteDataDeletionGenerationReceipt(
            fence: oldFence,
            acknowledgedAt: oldFence.updatedAt
        )

        XCTAssertEqual(
            CompleteDataDeletionLaunchGate.evaluate(
                pendingMarker: nil,
                localReceipt: oldReceipt,
                remoteFence: .found(currentFence)
            ),
            .eraseLocalStoreBeforeUse(currentFence)
        )
        XCTAssertFalse(
            CompleteDataDeletionLaunchDecision
                .eraseLocalStoreBeforeUse(currentFence)
                .permitsExistingPersistentStoreMount
        )
        XCTAssertFalse(CompleteDataDeletionWriteGate.permitsWrite(
            localReceipt: oldReceipt,
            verifiedRemoteFence: .found(currentFence)
        ))
        XCTAssertEqual(
            CompleteDataDeletionLaunchGate.evaluate(
                pendingMarker: nil,
                localReceipt: oldReceipt,
                remoteFence: .unavailable
            ),
            .block(.cloudUnavailable)
        )

        let currentReceipt = CompleteDataDeletionGenerationReceipt(
            fence: currentFence,
            acknowledgedAt: currentFence.updatedAt
        )
        XCTAssertEqual(
            CompleteDataDeletionLaunchGate.evaluate(
                pendingMarker: nil,
                localReceipt: currentReceipt,
                remoteFence: .found(currentFence)
            ),
            .allowGeneration(currentFence)
        )
        XCTAssertTrue(CompleteDataDeletionWriteGate.permitsWrite(
            localReceipt: currentReceipt,
            verifiedRemoteFence: .found(currentFence)
        ))
    }

    func testPendingFenceIsAdoptedSoAnotherDeviceCanFinishDeletion() {
        let pendingFence = fence(sequence: 3, state: .pending)
        let adoptedDecision = CompleteDataDeletionLaunchGate.evaluate(
            pendingMarker: nil,
            localReceipt: nil,
            remoteFence: .found(pendingFence)
        )
        guard case let .resumeDeletion(adopted) = adoptedDecision else {
            return XCTFail("pending remote deletion must be resumable")
        }
        XCTAssertEqual(adopted.transactionID, pendingFence.transactionID)
        XCTAssertEqual(adopted.requestedGenerationID, pendingFence.generationID)
        XCTAssertEqual(adopted.fence, pendingFence)
        XCTAssertEqual(adopted.phase, .quiesceApplication)
        XCTAssertFalse(adoptedDecision.permitsExistingPersistentStoreMount)

        let marker = CompleteDataDeletionPendingMarker(
            transactionID: pendingFence.transactionID,
            requestedGenerationID: pendingFence.generationID,
            startedAt: pendingFence.createdAt
        )
        let resumeDecision = CompleteDataDeletionLaunchGate.evaluate(
            pendingMarker: marker,
            localReceipt: nil,
            remoteFence: .unavailable,
            availabilityPolicy: .offlineFirst
        )
        XCTAssertEqual(resumeDecision, .resumeDeletion(marker))
        XCTAssertFalse(resumeDecision.permitsExistingPersistentStoreMount)
        XCTAssertTrue(resumeDecision.requiresBlockingRecovery)
    }

    func testLaunchPreflightPersistsAnAdoptedRemotePendingFence() async throws {
        let pendingFence = fence(sequence: 9, state: .pending)
        let state = MemoryDeletionStateStore()
        let remote = StubRemoteStore(
            failZoneDeletionCount: 0,
            currentFence: pendingFence
        )
        let preflight = CompleteDataDeletionLaunchPreflight(
            stateStore: state,
            remoteStore: remote,
            availabilityPolicy: .offlineFirst
        )

        let decision = try await preflight.evaluate()
        guard case let .resumeDeletion(marker) = decision else {
            return XCTFail("pending fence must be adopted")
        }
        let persistedMarker = await state.loadPendingMarker()
        XCTAssertEqual(marker.fence, pendingFence)
        XCTAssertEqual(persistedMarker, marker)
    }

    func testOfflineFirstAllowsPreviouslyVerifiedStoreButQuarantinesUnknownGeneration() {
        let localFence = fence(sequence: 4, state: .committed)
        let localReceipt = CompleteDataDeletionGenerationReceipt(
            fence: localFence,
            acknowledgedAt: localFence.updatedAt
        )

        let decisionWithReceipt = CompleteDataDeletionLaunchGate.evaluate(
            pendingMarker: nil,
            localReceipt: localReceipt,
            remoteFence: .unavailable,
            availabilityPolicy: .offlineFirst
        )
        XCTAssertEqual(decisionWithReceipt, .allowUnverifiedOffline(localReceipt))
        XCTAssertTrue(decisionWithReceipt.permitsExistingPersistentStoreMount)

        let firstLaunchDecision = CompleteDataDeletionLaunchGate.evaluate(
            pendingMarker: nil,
            localReceipt: nil,
            remoteFence: .unavailable,
            availabilityPolicy: .offlineFirst
        )
        XCTAssertEqual(firstLaunchDecision, .block(.cloudUnavailable))
        XCTAssertFalse(firstLaunchDecision.permitsExistingPersistentStoreMount)
    }

    func testKnownRemoteMismatchNeverPermitsTheExistingStoreEvenWithOfflineFirstPolicy() {
        let localFence = fence(sequence: 5, state: .committed)
        let remoteFence = fence(sequence: 6, state: .committed)
        let localReceipt = CompleteDataDeletionGenerationReceipt(
            fence: localFence,
            acknowledgedAt: localFence.updatedAt
        )

        let decision = CompleteDataDeletionLaunchGate.evaluate(
            pendingMarker: nil,
            localReceipt: localReceipt,
            remoteFence: .found(remoteFence),
            availabilityPolicy: .offlineFirst
        )

        XCTAssertEqual(decision, .eraseLocalStoreBeforeUse(remoteFence))
        XCTAssertFalse(decision.permitsExistingPersistentStoreMount)
        XCTAssertTrue(decision.requiresBlockingRecovery)
    }

    func testFenceLookupUsesHardCloudKitTimeoutsAndMapsTimeoutToUnavailable() throws {
        let operation = CloudKitCompleteDataDeletionRemoteStore
            .makeFenceLookupOperation()

        XCTAssertEqual(
            operation.configuration.timeoutIntervalForRequest,
            CloudKitCompleteDataDeletionRemoteStore.fenceLookupRequestTimeout,
            accuracy: 0.001
        )
        XCTAssertEqual(
            operation.configuration.timeoutIntervalForResource,
            CloudKitCompleteDataDeletionRemoteStore.fenceLookupResourceTimeout,
            accuracy: 0.001
        )
        XCTAssertLessThanOrEqual(
            operation.configuration.timeoutIntervalForResource,
            3
        )

        let timedOut: Result<CKRecord?, any Error> = .failure(
            URLError(.timedOut)
        )
        XCTAssertEqual(
            CloudKitCompleteDataDeletionRemoteStore.lookup(
                fromBoundedFetch: timedOut
            ),
            .unavailable
        )

        let malformed = CKRecord(
            recordType: CloudKitCompleteDataDeletionRemoteStore.fenceRecordType,
            recordID: try XCTUnwrap(operation.recordIDs?.first)
        )
        let malformedResult: Result<CKRecord?, any Error> = .success(malformed)
        XCTAssertEqual(
            CloudKitCompleteDataDeletionRemoteStore.lookup(
                fromBoundedFetch: malformedResult
            ),
            .invalid
        )
        let invalidDecision = CompleteDataDeletionLaunchGate.evaluate(
            pendingMarker: nil,
            localReceipt: nil,
            remoteFence: .invalid,
            availabilityPolicy: .offlineFirst
        )
        XCTAssertEqual(invalidDecision, .block(.remoteFenceInvalid))
        XCTAssertFalse(invalidDecision.permitsExistingPersistentStoreMount)
    }

    func testLaunchPreflightAcknowledgesOnlyTheFenceVerifiedAfterLocalErasure() async throws {
        let currentFence = fence(sequence: 8, state: .committed)
        let state = MemoryDeletionStateStore()
        let remote = StubRemoteStore(
            failZoneDeletionCount: 0,
            currentFence: currentFence
        )
        let preflight = CompleteDataDeletionLaunchPreflight(
            stateStore: state,
            remoteStore: remote
        )

        let initialDecision = try await preflight.evaluate()
        XCTAssertEqual(initialDecision, .eraseLocalStoreBeforeUse(currentFence))
        try await preflight.acknowledgeErasedStore(
            for: currentFence,
            at: currentFence.updatedAt
        )
        let acknowledgedDecision = try await preflight.evaluate()
        XCTAssertEqual(acknowledgedDecision, .allowGeneration(currentFence))
    }

    func testArtifactCleanerDeletesOnlyOwnedExportsGIFsAndAllAppGroupEntries() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "CompleteDataDeletionArtifacts-\(UUID().uuidString)",
            isDirectory: true
        )
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        let appGroup = root.appendingPathComponent("group", isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: appGroup, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let export = temporary.appendingPathComponent(
            TsumibenDataExportPolicy.directoryPrefix + UUID().uuidString,
            isDirectory: true
        )
        let invalidExport = temporary.appendingPathComponent(
            TsumibenDataExportPolicy.directoryPrefix + "not-a-uuid",
            isDirectory: true
        )
        let gif = temporary.appendingPathComponent(
            AnimatedShareExporter.temporaryFilePrefix + UUID().uuidString
        ).appendingPathExtension("gif")
        let unrelated = temporary.appendingPathComponent("keep-me.txt")
        try fileManager.createDirectory(at: export, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: invalidExport, withIntermediateDirectories: false)
        try Data("gif".utf8).write(to: gif)
        try Data("unrelated".utf8).write(to: unrelated)
        try Data("snapshot".utf8).write(
            to: appGroup.appendingPathComponent("nested.bin")
        )
        try fileManager.createDirectory(
            at: appGroup.appendingPathComponent("subdirectory"),
            withIntermediateDirectories: false
        )

        let counts = try CompleteDataDeletionArtifactCleaner.clearAllOwnedArtifacts(
            temporaryDirectory: temporary,
            appGroupContainerURL: appGroup,
            fileManager: fileManager
        )

        XCTAssertEqual(counts.exportDirectories, 1)
        XCTAssertEqual(counts.animatedGIFs, 1)
        XCTAssertEqual(counts.appGroupEntries, 2)
        XCTAssertFalse(fileManager.fileExists(atPath: export.path))
        XCTAssertFalse(fileManager.fileExists(atPath: gif.path))
        XCTAssertTrue(fileManager.fileExists(atPath: invalidExport.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelated.path))
        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: appGroup.path).isEmpty)
    }

    func testPersistentStoreCleanerDeletesOnlyExactStoresAndKnownSidecars() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "CompleteDataDeletionStores-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let store = root.appendingPathComponent("Tsumiben.store")
        let artifacts = CompleteDataDeletionPersistentStoreCleaner.artifacts(for: store)
        for artifact in artifacts {
            if artifact.lastPathComponent.hasSuffix("_SUPPORT")
                || artifact.lastPathComponent.hasSuffix("_ckAssets") {
                try fileManager.createDirectory(
                    at: artifact,
                    withIntermediateDirectories: false
                )
                try Data("owned".utf8).write(
                    to: artifact.appendingPathComponent("payload")
                )
            } else {
                try Data("owned".utf8).write(to: artifact)
            }
        }
        let unrelated = root.appendingPathComponent("keep-me.sqlite")
        try Data("unrelated".utf8).write(to: unrelated)

        try CompleteDataDeletionPersistentStoreCleaner.removeStores(
            at: [store],
            fileManager: fileManager
        )

        for artifact in artifacts {
            XCTAssertFalse(fileManager.fileExists(atPath: artifact.path))
        }
        XCTAssertTrue(fileManager.fileExists(atPath: unrelated.path))
        XCTAssertThrowsError(
            try CompleteDataDeletionPersistentStoreCleaner.removeStores(
                at: [URL(fileURLWithPath: "/Tsumiben.store")],
                fileManager: fileManager
            )
        )
    }

    func testDefaultsCleanerRemovesEveryPersistedKey() throws {
        let domain = "CompleteDataDeletionDefaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("private", forKey: "focus.device-identity.v1")
        defaults.set(true, forKey: "onboarding.completed")
        defaults.set(Data([1, 2, 3]), forKey: "focus.recovery.v1")

        try CompleteDataDeletionDefaultsCleaner.clear(
            defaults: defaults,
            persistentDomainName: domain
        )

        XCTAssertNil(defaults.persistentDomain(forName: domain))
        XCTAssertNil(defaults.object(forKey: "focus.device-identity.v1"))
        XCTAssertNil(defaults.object(forKey: "onboarding.completed"))
        XCTAssertNil(defaults.object(forKey: "focus.recovery.v1"))
    }

    func testFileStateStoreRoundTripsPendingAndReceiptOutsideUserDefaults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CompleteDataDeletionState-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompleteDataDeletionFileStateStore(directoryURL: directory)
        var marker = CompleteDataDeletionPendingMarker(
            transactionID: UUID(),
            requestedGenerationID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_820_000_000)
        )
        let pendingFence = CompleteDataDeletionFence(
            generationID: marker.requestedGenerationID,
            transactionID: marker.transactionID,
            sequence: 4,
            state: .pending,
            createdAt: marker.startedAt,
            updatedAt: marker.startedAt
        )
        marker.fence = pendingFence
        marker.phase = .deletePrivateCloudData
        try await store.savePendingMarker(marker)
        let loadedMarker = try await store.loadPendingMarker()
        XCTAssertEqual(loadedMarker, marker)

        let committed = pendingFence.committed(at: marker.startedAt.addingTimeInterval(1))
        let receipt = CompleteDataDeletionGenerationReceipt(
            fence: committed,
            acknowledgedAt: committed.updatedAt
        )
        try await store.saveGenerationReceipt(receipt)
        let loadedReceipt = try await store.loadGenerationReceipt()
        XCTAssertEqual(loadedReceipt, receipt)
        try await store.removePendingMarker()
        let removedMarker = try await store.loadPendingMarker()
        let retainedReceipt = try await store.loadGenerationReceipt()
        XCTAssertNil(removedMarker)
        XCTAssertEqual(retainedReceipt, receipt)
    }

    private func fence(
        sequence: Int64,
        state: CompleteDataDeletionFence.State
    ) -> CompleteDataDeletionFence {
        let date = Date(timeIntervalSince1970: 1_830_000_000 + Double(sequence))
        return CompleteDataDeletionFence(
            generationID: UUID(),
            transactionID: UUID(),
            sequence: sequence,
            state: state,
            createdAt: date,
            updatedAt: date
        )
    }
}

private enum CompleteDataDeletionExpectedFailure: Error {
    case cloudUnavailable
    case journalRemoval
}

private final class LockedIDSource: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}

private actor MemoryDeletionStateStore: CompleteDataDeletionStateStoring {
    private var pending: CompleteDataDeletionPendingMarker?
    private var receipt: CompleteDataDeletionGenerationReceipt?
    private var failMarkerRemovalCount: Int

    init(failMarkerRemovalCount: Int = 0) {
        self.failMarkerRemovalCount = failMarkerRemovalCount
    }

    func loadPendingMarker() -> CompleteDataDeletionPendingMarker? { pending }

    func savePendingMarker(_ marker: CompleteDataDeletionPendingMarker) {
        pending = marker
    }

    func removePendingMarker() throws {
        if failMarkerRemovalCount > 0 {
            failMarkerRemovalCount -= 1
            throw CompleteDataDeletionExpectedFailure.journalRemoval
        }
        pending = nil
    }

    func loadGenerationReceipt() -> CompleteDataDeletionGenerationReceipt? { receipt }

    func saveGenerationReceipt(_ receipt: CompleteDataDeletionGenerationReceipt) {
        self.receipt = receipt
    }
}

private actor StubRemoteStore: CompleteDataDeletionRemoteStoring {
    private var currentFence: CompleteDataDeletionFence?
    private var failZoneDeletionCount: Int
    private var transactions: [UUID] = []
    private var deleteCount = 0

    init(
        failZoneDeletionCount: Int,
        currentFence: CompleteDataDeletionFence? = nil
    ) {
        self.failZoneDeletionCount = failZoneDeletionCount
        self.currentFence = currentFence
    }

    func establishPendingFence(
        transactionID: UUID,
        requestedGenerationID: UUID,
        requestedAt: Date
    ) -> CompleteDataDeletionFence {
        if let currentFence,
           currentFence.transactionID == transactionID,
           currentFence.generationID == requestedGenerationID {
            return currentFence
        }
        transactions.append(transactionID)
        let fence = CompleteDataDeletionFence(
            generationID: requestedGenerationID,
            transactionID: transactionID,
            sequence: 7,
            state: .pending,
            createdAt: requestedAt,
            updatedAt: requestedAt
        )
        currentFence = fence
        return fence
    }

    func deletePrivateCloudData(
        preserving fence: CompleteDataDeletionFence
    ) throws -> CompleteDataDeletionCloudReceipt {
        deleteCount += 1
        if failZoneDeletionCount > 0 {
            failZoneDeletionCount -= 1
            throw CompleteDataDeletionExpectedFailure.cloudUnavailable
        }
        return CompleteDataDeletionCloudReceipt(deletedZoneCount: 2)
    }

    func commitFence(
        _ fence: CompleteDataDeletionFence,
        committedAt: Date
    ) -> CompleteDataDeletionFence {
        let committed = fence.committed(at: committedAt)
        currentFence = committed
        return committed
    }

    func fetchFence() -> CompleteDataDeletionRemoteFenceLookup {
        currentFence.map(CompleteDataDeletionRemoteFenceLookup.found) ?? .absent
    }

    func establishedTransactions() -> [UUID] { transactions }
    func zoneDeleteCalls() -> Int { deleteCount }
}

private actor StubLocalModelStore: CompleteDataDeletionLocalModelStoring {
    private var count = 0

    func deleteAllModels() -> CompleteDataDeletionModelCounts {
        count += 1
        return .zero
    }

    func counts() -> CompleteDataDeletionModelCounts { .zero }
    func deleteCalls() -> Int { count }
}

@MainActor
private final class StubDeviceState: CompleteDataDeletionDeviceStateClearing {
    private(set) var quiesceCalls = 0
    private(set) var clearCalls = 0

    func quiesceApplication() {
        quiesceCalls += 1
    }

    func clearDeviceState() {
        clearCalls += 1
    }
}
