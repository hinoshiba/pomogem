import CloudKit
import CoreData
import Foundation
import SwiftData
import XCTest
@testable import PomoGem

/// Operator-only Development audit. The private runner must verify the actual
/// signed host's Development entitlement before installing or running it.
/// Environment strings are additional opt-ins, never entitlement evidence.
/// Each phase runs in a new hosted XCTest process with the ordinary app using
/// LOCAL_PREVIEW. Runtime process/mirror guards are never reset or bypassed.
@MainActor
final class RealDeviceStorageTransferLifecycleTests: XCTestCase {
    func testDevelopmentStorageTransferPhase() async throws {
        #if !DEBUG || targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly verified physical Debug Development host")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["POMOGEM_REAL_TRANSFER_LIFECYCLE"] == "1" else {
            throw XCTSkip("Development storage transfer lifecycle is explicitly opt-in")
        }
        guard environment["POMOGEM_TRANSFER_EXPECTED_CLOUD_ENV"] == "Development",
              environment["POMOGEM_LOCAL_PREVIEW"] == "1",
              Bundle.main.object(forInfoDictionaryKey: "PomoGemStorageTransferAuditHostIsolation") as? String == "placeholder-v1",
              !environment.keys.contains(where: {
                  $0.hasPrefix("POMOGEM_UI_TEST") || $0 == "POMOGEM_REAL_STORAGE_TRANSFER"
                      || $0 == "POMOGEM_REAL_CLOUD_DELETE" || $0 == "POMOGEM_REAL_SWIFTDATA_LIFECYCLE"
              }),
              let phase = DevelopmentTransferPhase(rawValue: environment["POMOGEM_TRANSFER_PHASE"] ?? ""),
              let runID = UUID(uuidString: environment["POMOGEM_TRANSFER_RUN_ID"] ?? "") else {
            return XCTFail("Conflicting or incomplete Development audit opt-in")
        }
        executionTimeAllowance = 600
        let runner = try DevelopmentTransferRunner(runID: runID, phase: phase,
            expectedTransactionID: environment["POMOGEM_TRANSFER_TRANSACTION_ID"].flatMap(UUID.init(uuidString:)))
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await runner.run() }
                group.addTask {
                    try await Task.sleep(for: .seconds(480))
                    throw DevelopmentTransferFailure.deadline
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch { runner.recordFailure(error) }
        let data = try runner.publish()
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Development storage transfer phase"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(runner.report.succeeded, "Phase failed; inspect the sanitized private evidence")
        #endif
    }
}

#if DEBUG && !targetEnvironment(simulator)
private enum DevelopmentTransferPhase: String, Codable {
    case synthetic, syntheticResume = "synthetic-resume", seedLocal = "seed-local", beginReplace = "begin-replace"
    case beginKeep = "begin-keep", beginDisable = "begin-disable"
    case resume, inspect, baseline, observeStores = "observe-stores", verify, mutateLocal = "mutate-local", cancelLocal = "cancel-local"
    case recoverRemote = "recover-remote", cancelRemote = "cancel-remote"
    case noneWriteProbe = "none-write-probe", mirrorExportProbe = "mirror-export-probe"
    case sameProcessProbe = "same-process-probe", sameProcessExport = "same-process-export"
}

private enum DevelopmentTransferFailure: String, Error {
    case deadline, precondition, differentPendingTransaction, differentProcessRequired
    case missingAuditState, unexpectedResult, snapshotMismatch, invalidFixture
}

private struct DevelopmentTransferState: Codable, Equatable {
    let version: Int
    let runID: UUID
    var lastProcessNonce: UUID?
    var syntheticManifest: StorageTransferRecoveryManifest?
    var sourceSnapshotDigest: String?
    var sourceSelection: PersistenceDeploymentSelection?
    var runtimeTransactionID: UUID?
    var expectedDestinationDigest: String?
    var expectedDestinationCloudOnly: Bool?
    var baselineCloudDigest: String?
    var localMutationCount: Int?
    var noneProbeSelection: PersistenceDeploymentSelection?
    var noneProbeControl: StorageTransferRecoveryControl?
    var noneProbeExpectedDigest: String?
    var sameProcessProbeExpectedDigest: String?
}

private struct DevelopmentTransferReport: Encodable {
    let evidenceVersion = 1
    let requestedEnvironment = "Development"
    let entitlementVerificationIsExternal = true
    let ordinaryHostRootIsDisabledByPrivateBuild = true
    let ordinaryHostCreatesNoModelContainer = true
    let isShippingUIEvidence = false
    let processNonce: UUID
    let phase: String
    let recordedAt = Date()
    var succeeded = false
    var stage = "preconditions"
    var disposition: String?
    var transactionID: UUID?
    var journalPhase: Int?
    var remotePhase: Int?
    var controlSchemaWriteAndReadAcknowledged = false
    var chunkAssetWriteAndReadAcknowledged = false
    var payloadByteExact = false
    var terminalReceiptAcknowledged = false
    var exactChunkAbsenceAcknowledged = false
    var accountStable = false
    var noNormalCloudMirrorOpened = false
    var sourceRecordCounts: [String: Int] = [:]
    var serverRecordCounts: [String: Int] = [:]
    var managedZoneCount: Int?
    var baselineCloudSnapshotDigest: String?
    var sourceAndCloudDifferBeforeChoice: Bool?
    var cloudUnchangedByLocalMutation: Bool?
    var sameStoreSynchronizationDisabledHoldSeconds: Int?
    var insertedSubjectCount: Int?
    var insertedSessionCount: Int?
    var deletedAchievementCount: Int?
    var snapshotRetainedAfterMirror: Bool?
    var sameProcessTransitionCompleted: Bool?
    var initialMirrorReleaseProven: Bool?
    var initialMirrorSetupAcknowledged: Bool?
    var noneContainerReleaseProven: Bool?
    var nativeCloudEventCounts: [String: Int]?
    var sourceSnapshotDigest: String?
    var localGraphMatchesFixture = false
    var serverGraphMatchesLocal = false
    var runtimeConstructedContainers = 0
    var runtimeConstructedCloudContainer = false
    var recordChangeTagStableAcrossFetches: Bool?
    var controlContentStableAcrossFetches: Bool?
    var opaqueProofStableAcrossFetches: Bool?
    var opaqueProofStableReencodingOneRecord: Bool?
    var opaqueProofByteCounts: [Int] = []
    var liveOperation: String?
    var saveAndFetchRevisionMatches: [Bool] = []
    var saveAndFetchProofMatches: [Bool] = []
    var saveAndFetchControlMatches: [Bool] = []
    var failureKind: String?
    var cloudErrorCode: Int?
}

@MainActor
private final class DevelopmentTransferRunner {
    private static let processNonce = UUID()
    private let runID: UUID
    private let phase: DevelopmentTransferPhase
    private let expectedTransactionID: UUID?
    private let directory: URL
    private let stateFile: StorageTransferStateFile<DevelopmentTransferState>
    private var state: DevelopmentTransferState
    private(set) var report: DevelopmentTransferReport

    init(runID: UUID, phase: DevelopmentTransferPhase, expectedTransactionID: UUID?) throws {
        self.runID = runID
        self.phase = phase
        self.expectedTransactionID = expectedTransactionID
        let documents = try FileManager.default.url(for: .documentDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        directory = documents.appendingPathComponent("StorageTransferDevelopmentAudit", isDirectory: true)
        stateFile = try StorageTransferStateFile(url: directory.appendingPathComponent("state-v1.json"))
        state = try stateFile.load() ?? DevelopmentTransferState(version: 1, runID: runID)
        guard state.version == 1, state.runID == runID else { throw DevelopmentTransferFailure.missingAuditState }
        report = DevelopmentTransferReport(processNonce: Self.processNonce, phase: phase.rawValue)
    }

    func run() async throws {
        guard !StorageTransferProcessState.cloudMirrorWasOpened,
              state.lastProcessNonce != Self.processNonce else {
            throw DevelopmentTransferFailure.differentProcessRequired
        }
        let previous = try stateFile.load()
        state.lastProcessNonce = Self.processNonce
        try stateFile.save(state, replacing: previous)
        report.noNormalCloudMirrorOpened = true
        _ = try publish()
        let lease = StorageTransferAccountLease(center: .default)
        defer { lease.stop() }
        let validate: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            try lease.check()
        }
        let runtime = try StorageTransferRuntime.live()
        if phase == .sameProcessProbe {
            try await sameProcessProbe(runtime: runtime, validate: validate)
        } else if phase == .sameProcessExport {
            try await mirrorExportProbe(runtime: runtime, sameProcessExpected: true, validate: validate)
        } else if phase == .noneWriteProbe {
            try await noneWriteProbe(runtime: runtime, validate: validate)
        } else if phase == .mirrorExportProbe {
            try await mirrorExportProbe(runtime: runtime, validate: validate)
        } else if phase == .baseline {
            guard try runtime.pendingLocalJournal() == nil,
                  PersistenceDeploymentState.load() == .unselected else { throw DevelopmentTransferFailure.precondition }
            let binding = try await AppleAccountBoundaryResolver().resolve().binding
            let control = try await runtime.remoteRecoveryStatus(binding: binding, validateAccess: validate)
            guard control?.blocksWriters != true else { throw DevelopmentTransferFailure.differentPendingTransaction }
            let remote = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: binding, validateTransfer: validate)
            guard try await runtime.remoteRecoveryStatus(binding: binding, validateAccess: validate) == control else {
                throw DevelopmentTransferFailure.differentPendingTransaction
            }
            let receipt = try remote.snapshot.write(to: directory.appendingPathComponent("baseline-cloud-v1.json"))
            let previous = state
            state.baselineCloudDigest = receipt.sha256
            try stateFile.save(state, replacing: previous)
            report.baselineCloudSnapshotDigest = receipt.sha256
            report.serverRecordCounts = remote.snapshot.recordCounts
            report.managedZoneCount = remote.zones.count
            report.accountStable = true
            report.disposition = "completeBaselineServerReadOnly"
        } else if phase == .seedLocal {
            try seedLocal(runtime: runtime)
        } else if phase == .synthetic || phase == .syntheticResume {
            try await synthetic(runtime: runtime, validate: validate)
        } else if phase == .mutateLocal {
            try await mutateLocal(runtime: runtime, validate: validate)
        } else if phase == .beginReplace || phase == .beginKeep || phase == .beginDisable {
            try await begin(runtime: runtime, validate: validate)
        } else if phase == .resume {
            let journal = try pinnedJournal(runtime)
            report.transactionID = journal.transactionID
            report.stage = "runtimeResume"
            _ = try publish()
            do {
                try await runtime.resumePendingTransfer(validateAccess: validate, trackContainer: { [self] _, cloud in
                    report.runtimeConstructedContainers += 1
                    report.runtimeConstructedCloudContainer = report.runtimeConstructedCloudContainer || cloud
                })
                guard try runtime.pendingLocalJournal() == nil else { throw DevelopmentTransferFailure.unexpectedResult }
                report.disposition = "completed"
            } catch StorageTransferRuntimeError.relaunchRequired {
                report.disposition = "relaunchRequired"
            }
            report.journalPhase = try runtime.pendingLocalJournal()?.phase.rawValue
        } else if phase == .cancelLocal {
            let journal = try pinnedJournal(runtime)
            guard journal.permitsCancellation else { throw DevelopmentTransferFailure.precondition }
            try await runtime.cancelPendingTransfer(expectedTransactionID: journal.transactionID, validateAccess: validate)
            guard try runtime.pendingLocalJournal() == nil else { throw DevelopmentTransferFailure.unexpectedResult }
            report.transactionID = journal.transactionID
            report.disposition = "cancelledRelaunchRequired"
        } else if phase == .recoverRemote || phase == .cancelRemote {
            guard let expectedTransactionID else { throw DevelopmentTransferFailure.precondition }
            let binding = try await AppleAccountBoundaryResolver().resolve().binding
            guard let control = try await runtime.remoteRecoveryStatus(binding: binding, validateAccess: validate),
                  control.manifest.transactionID == expectedTransactionID, control.blocksWriters else {
                throw DevelopmentTransferFailure.differentPendingTransaction
            }
            report.transactionID = expectedTransactionID
            if phase == .recoverRemote {
                try await runtime.recoverRemoteTransfer(binding: binding,
                    expectedTransactionID: expectedTransactionID, validateAccess: validate)
                guard try runtime.pendingLocalJournal()?.transactionID == expectedTransactionID else {
                    throw DevelopmentTransferFailure.unexpectedResult
                }
                report.disposition = "recoveredRelaunchRequired"
            } else {
                try await runtime.cancelRemoteTransfer(binding: binding,
                    expectedTransactionID: expectedTransactionID, validateAccess: validate)
                report.disposition = "cancelledRelaunchRequired"
            }
        } else if phase == .observeStores {
            guard try runtime.pendingLocalJournal() == nil,
                  case let .selected(selection) = PersistenceDeploymentState.load() else {
                throw DevelopmentTransferFailure.precondition
            }
            let urls = try PersistenceStoreTopology.persistentStoreURLs(for: selection.storageLaunchMode,
                accountNamespace: selection.storageNamespace)
            let container = try StorageTransferPersistence.makeContainer(selection: selection, urls: urls, cloudEnabled: false)
            let snapshot = try PomoGemStorageSnapshot.capture(from: ModelContext(container))
            let receipt = try snapshot.write(to: directory.appendingPathComponent("observed-local-v1.json"))
            let expected: ActiveAccountLocalBinding?
            if case .cloud(let binding) = selection { expected = binding } else { expected = nil }
            let binding = try await AppleAccountBoundaryResolver().resolve(expectedBinding: expected).binding
            let cloud = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: binding, validateTransfer: validate)
            _ = try cloud.snapshot.write(to: directory.appendingPathComponent("observed-cloud-v1.json"))
            report.sourceSnapshotDigest = receipt.sha256
            report.sourceRecordCounts = snapshot.recordCounts
            report.serverRecordCounts = cloud.snapshot.recordCounts
            report.serverGraphMatchesLocal = try snapshot.isEquivalent(to: cloud.snapshot,
                entities: PomoGemStorageSnapshot.cloudModelNames, normalizeEmptyRelationships: true, dateTolerance: 0.001)
            report.accountStable = true
            report.disposition = "observedStoresWithoutBootstrap"
        } else if phase == .verify {
            try await verify(runtime: runtime, validate: validate)
        } else {
            let pending = try runtime.pendingLocalJournal()
            report.journalPhase = pending?.phase.rawValue
            report.transactionID = pending?.transactionID
            let binding = try await AppleAccountBoundaryResolver().resolve(expectedBinding: pending?.cloudBinding).binding
            let control = try await runtime.remoteRecoveryStatus(binding: binding, validateAccess: validate)
            report.remotePhase = control?.phase.rawValue
            if report.transactionID == nil { report.transactionID = control?.manifest.transactionID }
            if control != nil {
                let transport = StorageTransferRecoveryCloudTransport()
                let first = try await transport.fetch(StorageTransferRecoveryCloudCodec.controlID)
                try validate()
                let second = try await transport.fetch(StorageTransferRecoveryCloudCodec.controlID)
                try validate()
                guard let first, let second else { throw DevelopmentTransferFailure.unexpectedResult }
                report.recordChangeTagStableAcrossFetches = first.record.recordChangeTag == second.record.recordChangeTag
                report.opaqueProofStableAcrossFetches = first.systemFieldsProof == second.systemFieldsProof
                report.opaqueProofStableReencodingOneRecord = first.systemFieldsProof == (try StorageTransferRecoveryCloudCodec.systemFields(first.record))
                report.opaqueProofByteCounts = [first.systemFieldsProof.utf8.count, second.systemFieldsProof.utf8.count]
                report.controlContentStableAcrossFetches = try StorageTransferRecoveryCloudCodec.decodeControl(first.record,
                    name: StorageTransferRecoverySchema.controlRecordName, terminal: false)
                    == StorageTransferRecoveryCloudCodec.decodeControl(second.record,
                        name: StorageTransferRecoverySchema.controlRecordName, terminal: false)
                _ = try await AppleAccountBoundaryResolver().resolve(expectedBinding: binding)
                try validate()
            }
            report.accountStable = true
            report.disposition = "observedOnly"
        }
        try validate()
        report.stage = "completed"
        report.succeeded = true
    }

    private func synthetic(runtime: StorageTransferRuntime,
                           validate: @escaping @MainActor () throws -> Void) async throws {
        guard PersistenceDeploymentState.load() == .unselected,
              PersistenceDeploymentState.loadMountState() == .unrecorded,
              try runtime.pendingLocalJournal() == nil else { throw DevelopmentTransferFailure.precondition }
        let binding = try await AppleAccountBoundaryResolver().resolve().binding
        let live = StorageTransferRecoveryCloudClient.live
        var savedControl: StorageTransferRecoveryCloudRecord?
        let traced = StorageTransferRecoveryCloudClient(verifyAccount: { [self] value in
            report.liveOperation = "verifyAccount"
            try await live.verifyAccount(value)
        }, fetch: { [self] id in
            report.liveOperation = id == StorageTransferRecoveryCloudCodec.controlID ? "fetchControl" : "fetchChunkOrReceipt"
            let result = try await live.fetch(id)
            if id == StorageTransferRecoveryCloudCodec.controlID, let result, let savedControl {
                report.saveAndFetchRevisionMatches.append(savedControl.record.recordChangeTag == result.record.recordChangeTag)
                report.saveAndFetchProofMatches.append(savedControl.systemFieldsProof == result.systemFieldsProof)
                report.saveAndFetchControlMatches.append(try StorageTransferRecoveryCloudCodec.decodeControl(savedControl.record,
                    name: StorageTransferRecoverySchema.controlRecordName, terminal: false)
                    == StorageTransferRecoveryCloudCodec.decodeControl(result.record,
                        name: StorageTransferRecoverySchema.controlRecordName, terminal: false))
            }
            return result
        }, save: { [self] record, proof in
            report.liveOperation = record.recordID == StorageTransferRecoveryCloudCodec.controlID ? "saveControl" : "saveChunkOrReceipt"
            let result = try await live.save(record, proof)
            if record.recordID == StorageTransferRecoveryCloudCodec.controlID { savedControl = result }
            return result
        }, ensureZone: { [self] id in
            report.liveOperation = "ensureRecoveryZone"
            try await live.ensureZone(id)
        }, delete: { [self] id in
            report.liveOperation = "deleteExactTerminalChunk"
            try await live.delete(id)
        })
        let backend = StorageTransferRemoteRecoveryCloudKit(client: traced, validateAccess: validate)
        let recovery = StorageTransferRemoteRecovery(backend: backend, validateAccess: validate)
        let before = try await recovery.inspect(accountFingerprint: binding.accountFingerprint)
        // A real shipping snapshot encoding, kept fully synthetic and split into
        // several CKAsset chunks. This phase never authorizes zone replacement.
        let payload: Data
        let manifest: StorageTransferRecoveryManifest
        if phase == .syntheticResume {
            guard let own = state.syntheticManifest, before?.control.manifest == own,
                  own.accountFingerprint == binding.accountFingerprint else {
                throw DevelopmentTransferFailure.differentPendingTransaction
            }
            // v14's initial empty synthetic snapshot has only these two possible
            // JSON key orders. Accept one only after the original SHA/chunks
            // validate; never reconstruct arbitrary user payloads this way.
            let candidates = ["{\"formatVersion\":1,\"records\":[]}", "{\"records\":[],\"formatVersion\":1}"]
                .map { Data($0.utf8) }
            guard let exact = candidates.first(where: { (try? own.validate(payload: $0)) != nil }) else {
                throw DevelopmentTransferFailure.snapshotMismatch
            }
            payload = exact
            manifest = own
        } else {
            guard before?.control.blocksWriters != true else {
                throw DevelopmentTransferFailure.differentPendingTransaction
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            payload = try encoder.encode(PomoGemStorageSnapshot(formatVersion: 1, records: []))
            manifest = try StorageTransferRecoveryManifest(transactionID: UUID(),
                accountFingerprint: binding.accountFingerprint, payload: payload, chunkByteLimit: 16,
                previousDatasetGenerationID: before?.control.datasetGenerationID)
        }
        let previous = state
        state.syntheticManifest = manifest
        try stateFile.save(state, replacing: previous)
        report.transactionID = manifest.transactionID
        report.stage = "syntheticStage"
        _ = try publish()
        let staged = try await recovery.stage(manifest: manifest, payload: payload,
            replacingTerminalTransactionID: before?.control.isTerminal == true ? before?.control.manifest.transactionID : nil)
        guard staged.envelope.control.phase == .backupVerified else { throw DevelopmentTransferFailure.unexpectedResult }
        report.controlSchemaWriteAndReadAcknowledged = true
        report.chunkAssetWriteAndReadAcknowledged = true
        let readback = try await recovery.recover(manifest: manifest)
        guard readback.bytes == payload else { throw DevelopmentTransferFailure.snapshotMismatch }
        report.payloadByteExact = true
        report.stage = "syntheticCancel"
        _ = try publish()
        let cancelled = try await recovery.cancelBeforeReplacement(manifest: manifest)
        guard cancelled.envelope.control.phase == .cancelled,
              try await backend.readTerminalReceipt(transactionID: manifest.transactionID) == cancelled.envelope.control else {
            throw DevelopmentTransferFailure.unexpectedResult
        }
        report.terminalReceiptAcknowledged = true
        report.stage = "syntheticCleanup"
        _ = try publish()
        try await recovery.cleanupPayload(manifest: manifest)
        for chunk in manifest.chunks {
            guard try await backend.readChunk(manifest: manifest, index: chunk.index) == nil else {
                throw DevelopmentTransferFailure.unexpectedResult
            }
        }
        report.exactChunkAbsenceAcknowledged = true
        let after = try await recovery.inspect(accountFingerprint: binding.accountFingerprint)
        guard after?.control == cancelled.envelope.control else { throw DevelopmentTransferFailure.unexpectedResult }
        report.accountStable = true
        report.remotePhase = after?.control.phase.rawValue
        report.disposition = "syntheticCancelledAndCleaned"
    }

    private func seedLocal(runtime: StorageTransferRuntime) throws {
        guard PersistenceDeploymentState.load() == .unselected,
              PersistenceDeploymentState.loadMountState() == .unrecorded,
              try runtime.pendingLocalJournal() == nil, state.sourceSnapshotDigest == nil,
              state.baselineCloudDigest != nil else {
            throw DevelopmentTransferFailure.precondition
        }
        let selection = PersistenceDeploymentSelection.localOnly(namespace: AccountDataNamespace())
        let urls = try PersistenceStoreTopology.persistentStoreURLs(for: .localOnly,
            accountNamespace: selection.storageNamespace)
        guard urls.flatMap(PersistenceStoreArtifactLayout.artifacts).allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
            throw DevelopmentTransferFailure.precondition
        }
        let container = try StorageTransferPersistence.makeContainer(selection: selection, urls: urls, cloudEnabled: false)
        let context = container.mainContext
        context.autosaveEnabled = false
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let marker = ActivityResetMarker(sequence: 0, resetAt: now, writerDeviceID: "audit-synthetic")
        let epoch = marker.epochID
        context.insert(marker)
        let subject = Subject(name: "PomoGem Development Transfer Synthetic", colorHex: "#123456", sortOrder: 0)
        context.insert(subject)
        context.insert(StudySession(subject: subject, startAt: now, endAt: now.addingTimeInterval(1_800),
            seconds: 1_800, source: .manual, deviceDayKey: "2023-11-14", dataEpochID: epoch))
        context.insert(AchievementStone(subject: subject, kind: .examPass, note: "Synthetic", achievedAt: now, dataEpochID: epoch))
        context.insert(Prefs(keepScreenAwake: false, hasCompletedOnboarding: true,
            activityEpochID: epoch, settingsWriterID: "audit-synthetic"))
        let sessionID = UUID()
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try engine.startFocus(isPro: false, now: now, sessionID: sessionID)
        var payload = try FocusCloudPayload(envelope: FocusRecoveryEnvelope(engine: engine,
            subject: FocusSubjectSnapshot(subject: subject), clockAnchor: nil, pendingCompletion: nil, savedAt: now))
        payload.dataEpochID = epoch
        context.insert(try SyncedFocusTimer(sessionID: sessionID, status: .cancelled, payload: payload,
            updatedAt: now, writerDeviceID: "audit-synthetic"))
        context.insert(FocusTimerDeviceClaim(sessionID: sessionID, deviceID: "audit-synthetic",
            sequence: 1, claimedAt: now, releasedAt: now, dataEpochID: epoch))
        context.insert(AggregatePebble(level: 2, pebbleCount: 1, grams: 300, colorMixJSON: "[]", periodStart: now, periodEnd: now, dataEpochID: epoch))
        context.insert(Stratum(pebbleCount: 1, heightPt: 20, colorMixJSON: "[]", monthLabel: "2023-11", dataEpochID: epoch))
        context.insert(Bedrock(hours: 10, importedAt: now, dataEpochID: epoch))
        context.insert(GachaState(sinceLastGold: 4, rewardCreditGrams: 300, dataEpochID: epoch))
        try context.save()
        let snapshot = try PomoGemStorageSnapshot.capture(from: ModelContext(container))
        guard snapshot.recordCounts.values.allSatisfy({ $0 == 1 }),
              snapshot.recordCounts.count == 11,
              try FocusCloudSyncStore.canonicalActive(context: ModelContext(container)) == nil else {
            throw DevelopmentTransferFailure.invalidFixture
        }
        let receipt = try snapshot.write(to: directory.appendingPathComponent("fixture-v1.json"))
        try PersistenceDeploymentState.select(selection)
        try PersistenceDeploymentState.recordSuccessfulMount(selection)
        let previous = state
        state.sourceSnapshotDigest = receipt.sha256
        state.sourceSelection = selection
        try stateFile.save(state, replacing: previous)
        report.sourceRecordCounts = snapshot.recordCounts
        report.sourceSnapshotDigest = receipt.sha256
        report.disposition = "localFixtureSavedNoCloudWrites"
    }

    private func begin(runtime: StorageTransferRuntime,
                       validate: @escaping @MainActor () throws -> Void) async throws {
        guard case let .selected(selection) = PersistenceDeploymentState.load(),
              try runtime.pendingLocalJournal() == nil else { throw DevelopmentTransferFailure.precondition }
        let choice: StorageTransferChoice = phase == .beginDisable ? .disableCloudKeepingCopy
            : (phase == .beginKeep ? .enableCloudKeepingCloud : .enableCloudReplacingCloud)
        let urls = try PersistenceStoreTopology.persistentStoreURLs(for: selection.storageLaunchMode,
            accountNamespace: selection.storageNamespace)
        let container = try StorageTransferPersistence.makeContainer(selection: selection, urls: urls, cloudEnabled: false)
        container.mainContext.autosaveEnabled = false
        let expected: PomoGemStorageSnapshot
        let localBefore = try PomoGemStorageSnapshot.capture(from: ModelContext(container))
        if choice == .enableCloudKeepingCloud {
            let binding = try await AppleAccountBoundaryResolver().resolve().binding
            expected = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: binding,
                validateTransfer: validate).snapshot
            report.sourceAndCloudDifferBeforeChoice = try !localBefore.isEquivalent(to: expected,
                entities: PomoGemStorageSnapshot.cloudModelNames, normalizeEmptyRelationships: true, dateTolerance: 0.001)
        } else { expected = localBefore }
        let expectedReceipt = try expected.write(to: directory.appendingPathComponent("expected-destination-v1.json"))
        report.stage = "runtimeBegin"
        _ = try publish()
        try await runtime.begin(choice: choice, source: selection, sourceContext: container.mainContext, validateAccess: validate)
        guard let journal = try runtime.pendingLocalJournal(), journal.phase == .requested,
              journal.source == selection else { throw DevelopmentTransferFailure.unexpectedResult }
        let previous = state
        state.runtimeTransactionID = journal.transactionID
        state.expectedDestinationDigest = expectedReceipt.sha256
        state.expectedDestinationCloudOnly = choice == .enableCloudKeepingCloud
        try stateFile.save(state, replacing: previous)
        report.transactionID = journal.transactionID
        report.journalPhase = journal.phase.rawValue
        do {
            try await runtime.resumePendingTransfer(validateAccess: validate, trackContainer: { _, _ in })
            throw DevelopmentTransferFailure.unexpectedResult
        } catch StorageTransferRuntimeError.relaunchRequired {
            report.disposition = "sameProcessResumeCorrectlyRefused"
        }
    }

    private func pinnedJournal(_ runtime: StorageTransferRuntime) throws -> StorageTransferJournal {
        guard let pinned = expectedTransactionID ?? state.runtimeTransactionID,
              let journal = try runtime.pendingLocalJournal(), journal.transactionID == pinned else {
            throw DevelopmentTransferFailure.differentPendingTransaction
        }
        return journal
    }

    private func mutateLocal(runtime: StorageTransferRuntime,
                             validate: @escaping @MainActor () throws -> Void) async throws {
        guard case let .selected(selection) = PersistenceDeploymentState.load(),
              case .localOnly = selection, try runtime.pendingLocalJournal() == nil else {
            throw DevelopmentTransferFailure.precondition
        }
        let binding = try await AppleAccountBoundaryResolver().resolve().binding
        let before = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: binding, validateTransfer: validate)
        let urls = try PersistenceStoreTopology.persistentStoreURLs(for: .localOnly,
            accountNamespace: selection.storageNamespace)
        let container = try StorageTransferPersistence.makeContainer(selection: selection, urls: urls, cloudEnabled: false)
        let context = container.mainContext
        context.autosaveEnabled = false
        let subjects = try context.fetch(FetchDescriptor<Subject>())
        let candidates = subjects.count == 1 ? subjects : subjects.filter { $0.name == "Audit Same Process None Updated" }
        guard candidates.count == 1, let subject = candidates.first, subject.deletedAt == nil else {
            throw DevelopmentTransferFailure.invalidFixture
        }
        let mutation = (state.localMutationCount ?? 0) + 1
        subject.name = "PomoGem Development Local Revision \(mutation)"
        try SubjectSyncPolicy.recordUserMutation(from: subject, among: subjects)
        try context.save()
        let snapshot = try PomoGemStorageSnapshot.capture(from: ModelContext(container))
        report.sourceAndCloudDifferBeforeChoice = try !snapshot.isEquivalent(to: before.snapshot,
            entities: PomoGemStorageSnapshot.cloudModelNames, normalizeEmptyRelationships: true, dateTolerance: 0.001)
        guard report.sourceAndCloudDifferBeforeChoice == true else { throw DevelopmentTransferFailure.unexpectedResult }
        let after = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: binding, validateTransfer: validate)
        report.cloudUnchangedByLocalMutation = try before.snapshot.isEquivalent(to: after.snapshot,
            entities: PomoGemStorageSnapshot.cloudModelNames, normalizeEmptyRelationships: true)
        guard report.cloudUnchangedByLocalMutation == true else { throw DevelopmentTransferFailure.snapshotMismatch }
        let previous = state
        state.localMutationCount = mutation
        try stateFile.save(state, replacing: previous)
        report.sourceRecordCounts = snapshot.recordCounts
        report.serverRecordCounts = after.snapshot.recordCounts
        report.accountStable = true
        report.disposition = "localEditedCloudUnchanged"
    }

    /// Network remains available. This verifies synchronization-disabled writes,
    /// not airplane mode or transport failure. Both phases use the same exact
    /// shipping cloud source/projection paths; the private runner separately
    /// compares NSStoreUUID and native history from read-only copied databases.
    private func noneWriteProbe(runtime: StorageTransferRuntime,
                                validate: @escaping @MainActor () throws -> Void) async throws {
        guard try runtime.pendingLocalJournal() == nil, state.noneProbeExpectedDigest == nil,
              case let .selected(selection) = PersistenceDeploymentState.load(),
              case let .cloud(binding) = selection else { throw DevelopmentTransferFailure.precondition }
        _ = try await AppleAccountBoundaryResolver().resolve(expectedBinding: binding)
        let control = try await runtime.remoteRecoveryStatus(binding: binding, validateAccess: validate)
        guard control?.blocksWriters != true else { throw DevelopmentTransferFailure.differentPendingTransaction }
        let cloudBefore = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: binding, validateTransfer: validate)
        let urls = try PersistenceStoreTopology.persistentStoreURLs(for: .cloudKit, accountNamespace: binding.namespace)
        let container = try StorageTransferPersistence.makeContainer(selection: selection, urls: urls, cloudEnabled: false)
        let context = container.mainContext
        context.autosaveEnabled = false
        if #available(iOS 18, *) { context.author = "PomoGemStorageTransferAudit.noneWrite" }
        let before = try PomoGemStorageSnapshot.capture(from: ModelContext(container))
        guard try before.isEquivalent(to: cloudBefore.snapshot, entities: PomoGemStorageSnapshot.cloudModelNames,
            normalizeEmptyRelationships: true, dateTolerance: 0.001) else { throw DevelopmentTransferFailure.snapshotMismatch }
        _ = try before.write(to: directory.appendingPathComponent("none-probe-before-v1.json"))
        _ = try cloudBefore.snapshot.write(to: directory.appendingPathComponent("none-probe-cloud-before-v1.json"))
        let subjects = try context.fetch(FetchDescriptor<Subject>())
        let stones = try context.fetch(FetchDescriptor<AchievementStone>())
        guard subjects.count == 1, let existing = subjects.first, stones.count == 1,
              let stone = stones.first, stone.note == "Synthetic" else { throw DevelopmentTransferFailure.invalidFixture }
        existing.name = "Audit None Updated"
        try SubjectSyncPolicy.recordUserMutation(from: existing, among: subjects)
        let inserted = Subject(name: "Audit None Inserted", colorHex: "#654321", sortOrder: 9)
        context.insert(inserted)
        let epoch = try ActivityResetStore.latestSnapshot(context: context)?.epochID
        let date = Date(timeIntervalSince1970: 1_700_123_456)
        context.insert(StudySession(subject: inserted, startAt: date, endAt: date.addingTimeInterval(600),
            seconds: 600, source: .manual, deviceDayKey: "2023-11-16", dataEpochID: epoch))
        context.delete(stone)
        try context.save()
        let expected = try PomoGemStorageSnapshot.capture(from: ModelContext(container))
        let receipt = try expected.write(to: directory.appendingPathComponent("none-probe-expected-v1.json"))
        let previous = state
        state.noneProbeSelection = selection
        state.noneProbeControl = control
        state.noneProbeExpectedDigest = receipt.sha256
        try stateFile.save(state, replacing: previous)
        report.sourceRecordCounts = expected.recordCounts
        report.sourceSnapshotDigest = receipt.sha256
        report.insertedSubjectCount = 1
        report.insertedSessionCount = 1
        report.deletedAchievementCount = 1
        report.stage = "holdingSynchronizationDisabledStore"
        _ = try publish()
        for _ in 0..<12 {
            try await Task.sleep(for: .seconds(5))
            try validate()
            guard !StorageTransferProcessState.cloudMirrorWasOpened,
                  PersistenceDeploymentState.load() == .selected(selection) else {
                throw DevelopmentTransferFailure.precondition
            }
        }
        let cloudAfter = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: binding, validateTransfer: validate)
        guard try await runtime.remoteRecoveryStatus(binding: binding, validateAccess: validate) == control else {
            throw DevelopmentTransferFailure.differentPendingTransaction
        }
        report.cloudUnchangedByLocalMutation = try cloudBefore.snapshot.isEquivalent(to: cloudAfter.snapshot,
            entities: PomoGemStorageSnapshot.cloudModelNames, normalizeEmptyRelationships: true)
        guard report.cloudUnchangedByLocalMutation == true,
              try expected.isEquivalent(to: PomoGemStorageSnapshot.capture(from: ModelContext(container))) else {
            throw DevelopmentTransferFailure.snapshotMismatch
        }
        report.sameStoreSynchronizationDisabledHoldSeconds = 60
        report.serverRecordCounts = cloudAfter.snapshot.recordCounts
        report.accountStable = true
        report.disposition = "sameStoreNoneWritesRetainedCloudUnchanged"
    }

    private func mirrorExportProbe(runtime: StorageTransferRuntime, sameProcessExpected: Bool = false,
                                   setupEvents: DevelopmentTransferCloudEvents? = nil,
                                   validate: @escaping @MainActor () throws -> Void) async throws {
        guard try runtime.pendingLocalJournal() == nil,
              let selection = state.noneProbeSelection,
              let digest = sameProcessExpected ? state.sameProcessProbeExpectedDigest : state.noneProbeExpectedDigest,
              PersistenceDeploymentState.load() == .selected(selection),
              case let .cloud(binding) = selection else { throw DevelopmentTransferFailure.precondition }
        let filename = sameProcessExpected ? "same-process-probe-expected-v1.json" : "none-probe-expected-v1.json"
        let expected = try PomoGemStorageSnapshot.read(from: directory.appendingPathComponent(filename), expectedDigest: digest)
        _ = try await AppleAccountBoundaryResolver().resolve(expectedBinding: binding)
        try await runtime.preflightCloudMount(binding: binding, validateAccess: validate)
        let control = try await runtime.remoteRecoveryStatus(binding: binding, validateAccess: validate)
        guard control == state.noneProbeControl, control?.blocksWriters != true else {
            throw DevelopmentTransferFailure.differentPendingTransaction
        }
        let markers = try expected.records.filter { $0.entity == "ActivityResetMarker" }.map { record in
            guard case let .uuid(id)? = record.fields["id"],
                  case let .uuid(epoch)? = record.fields["epochID"],
                  case let .integer(sequence)? = record.fields["sequence"],
                  case let .dateBits(bits)? = record.fields["resetAt"],
                  case let .string(writer)? = record.fields["writerDeviceID"] else {
                throw DevelopmentTransferFailure.invalidFixture
            }
            return ActivityResetSnapshot(id: id, epochID: epoch, sequence: sequence,
                resetAt: Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits)), writerDeviceID: writer)
        }
        try await CloudActivityHistoryPreflight().run(expectedBinding: binding, validateMount: validate,
            localMarker: { ActivityResetPolicy.currentMarker(from: markers) })
        guard try await runtime.remoteRecoveryStatus(binding: binding, validateAccess: validate) == control else {
            throw DevelopmentTransferFailure.differentPendingTransaction
        }
        let urls = try PersistenceStoreTopology.persistentStoreURLs(for: .cloudKit, accountNamespace: binding.namespace)
        StorageTransferProcessState.markCloudMirrorOpened()
        let container = try StorageTransferPersistence.makeContainer(selection: selection, urls: urls, cloudEnabled: true)
        report.runtimeConstructedCloudContainer = true
        report.runtimeConstructedContainers += 1
        report.stage = "waitingSameStoreExport"
        _ = try publish()
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while true {
            try validate()
            guard try await runtime.remoteRecoveryStatus(binding: binding, validateAccess: validate) == control else {
                throw DevelopmentTransferFailure.differentPendingTransaction
            }
            let cloud = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: binding, validateTransfer: validate)
            let snapshot = try PomoGemStorageSnapshot.observeCloudReplica(from: ModelContext(container))
            report.snapshotRetainedAfterMirror = try expected.isEquivalent(to: snapshot, normalizeEmptyRelationships: true)
            report.serverGraphMatchesLocal = try expected.isEquivalent(to: cloud.snapshot,
                entities: PomoGemStorageSnapshot.cloudModelNames, normalizeEmptyRelationships: true, dateTolerance: 0.001)
            let setupReady = setupEvents.map { $0.snapshot()["initialMirror.setup.succeeded", default: 0] > 0 } ?? true
            if setupEvents != nil { report.initialMirrorSetupAcknowledged = setupReady }
            if report.snapshotRetainedAfterMirror == true, report.serverGraphMatchesLocal, setupReady {
                report.sourceRecordCounts = snapshot.recordCounts
                report.serverRecordCounts = cloud.snapshot.recordCounts
                report.sourceSnapshotDigest = digest
                report.accountStable = true
                report.disposition = "sameStoreNoneInsertUpdateDeleteExported"
                return
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DevelopmentTransferFailure.snapshotMismatch }
            try await Task.sleep(for: .seconds(2))
        }
    }

    private func sameProcessProbe(runtime: StorageTransferRuntime,
                                  validate: @escaping @MainActor () throws -> Void) async throws {
        guard state.sameProcessProbeExpectedDigest == nil,
              let selection = state.noneProbeSelection, case let .cloud(binding) = selection,
              PersistenceDeploymentState.load() == .selected(selection) else {
            throw DevelopmentTransferFailure.precondition
        }
        let events = DevelopmentTransferCloudEvents()
        defer { report.nativeCloudEventCounts = events.snapshot() }
        events.setStage("initialMirror")
        try await mirrorExportProbe(runtime: runtime, setupEvents: events, validate: validate)
        guard StorageTransferProcessState.cloudMirrorWasOpened else { throw DevelopmentTransferFailure.precondition }
        events.setStage("retiringInitialMirror")
        report.initialMirrorReleaseProven = try await waitForProbeRelease(validate: validate)
        guard report.initialMirrorReleaseProven == true else {
            report.disposition = "sameProcessRelaunchRequiredBeforeNone"
            report.sameProcessTransitionCompleted = false
            return
        }
        try validate()
        guard try runtime.pendingLocalJournal() == nil,
              PersistenceDeploymentState.load() == .selected(selection),
              try await runtime.remoteRecoveryStatus(binding: binding, validateAccess: validate) == state.noneProbeControl else {
            throw DevelopmentTransferFailure.differentPendingTransaction
        }
        events.setStage("noneHeld")
        try await mutateAndHoldAfterMirror(runtime: runtime, selection: selection, binding: binding, validate: validate)
        events.setStage("retiringNone")
        report.noneContainerReleaseProven = try await waitForProbeRelease(validate: validate)
        guard report.noneContainerReleaseProven == true else {
            report.disposition = "sameProcessRelaunchRequiredAfterNoneWrites"
            report.sameProcessTransitionCompleted = false
            return
        }
        events.setStage("finalMirror")
        try await mirrorExportProbe(runtime: runtime, sameProcessExpected: true, validate: validate)
        guard StorageTransferProcessState.cloudMirrorWasOpened else { throw DevelopmentTransferFailure.precondition }
        report.sameProcessTransitionCompleted = true
        report.disposition = "sameProcessMirrorNoneMirrorCompleted"
    }

    private func waitForProbeRelease(validate: @escaping @MainActor () throws -> Void) async throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while true {
            try validate()
            do {
                try autoreleasepool { try StorageTransferPersistence.requireAllReleased() }
                return true
            } catch StorageTransferRuntimeError.relaunchRequired {
                if ProcessInfo.processInfo.systemUptime >= deadline { return false }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func mutateAndHoldAfterMirror(runtime: StorageTransferRuntime,
                                         selection: PersistenceDeploymentSelection,
                                         binding: ActiveAccountLocalBinding,
                                         validate: @escaping @MainActor () throws -> Void) async throws {
        let cloudBefore = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: binding, validateTransfer: validate)
        guard try await runtime.remoteRecoveryStatus(binding: binding, validateAccess: validate) == state.noneProbeControl else {
            throw DevelopmentTransferFailure.differentPendingTransaction
        }
        let urls = try PersistenceStoreTopology.persistentStoreURLs(for: .cloudKit, accountNamespace: binding.namespace)
        let container = try StorageTransferPersistence.makeContainer(selection: selection, urls: urls, cloudEnabled: false)
        defer { withExtendedLifetime(container) {} }
        report.runtimeConstructedContainers += 1
        let context = container.mainContext
        context.autosaveEnabled = false
        if #available(iOS 18, *) { context.author = "PomoGemStorageTransferAudit.sameProcessNoneWrite" }
        let before = try PomoGemStorageSnapshot.capture(from: ModelContext(container))
        guard try before.isEquivalent(to: cloudBefore.snapshot, entities: PomoGemStorageSnapshot.cloudModelNames,
            normalizeEmptyRelationships: true, dateTolerance: 0.001) else { throw DevelopmentTransferFailure.snapshotMismatch }
        _ = try before.write(to: directory.appendingPathComponent("same-process-probe-before-v1.json"))
        let subjects = try context.fetch(FetchDescriptor<Subject>())
        let targets = subjects.filter { $0.name == "Audit None Inserted" && $0.deletedAt == nil }
        guard targets.count == 1, let subject = targets.first else { throw DevelopmentTransferFailure.invalidFixture }
        subject.name = "Audit Same Process None Updated"
        try SubjectSyncPolicy.recordUserMutation(from: subject, among: subjects)
        try context.save()
        let expected = try PomoGemStorageSnapshot.capture(from: ModelContext(container))
        let receipt = try expected.write(to: directory.appendingPathComponent("same-process-probe-expected-v1.json"))
        let previous = state
        state.sameProcessProbeExpectedDigest = receipt.sha256
        try stateFile.save(state, replacing: previous)
        report.sourceSnapshotDigest = receipt.sha256
        report.sourceRecordCounts = expected.recordCounts
        report.cloudUnchangedByLocalMutation = nil
        report.stage = "holdingNoneAfterMirrorInSameProcess"
        _ = try publish()
        let started = ProcessInfo.processInfo.systemUptime
        repeat {
            try await Task.sleep(for: .seconds(10))
            try validate()
            guard StorageTransferProcessState.cloudMirrorWasOpened,
                  PersistenceDeploymentState.load() == .selected(selection),
                  try runtime.pendingLocalJournal() == nil,
                  try await runtime.remoteRecoveryStatus(binding: binding, validateAccess: validate) == state.noneProbeControl else {
                throw DevelopmentTransferFailure.differentPendingTransaction
            }
            let cloud = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: binding, validateTransfer: validate)
            report.cloudUnchangedByLocalMutation = try cloudBefore.snapshot.isEquivalent(to: cloud.snapshot,
                entities: PomoGemStorageSnapshot.cloudModelNames, normalizeEmptyRelationships: true)
            guard report.cloudUnchangedByLocalMutation == true,
                  try expected.isEquivalent(to: PomoGemStorageSnapshot.capture(from: ModelContext(container))) else {
                throw DevelopmentTransferFailure.snapshotMismatch
            }
        } while ProcessInfo.processInfo.systemUptime - started < 60
        report.sameStoreSynchronizationDisabledHoldSeconds = Int(ProcessInfo.processInfo.systemUptime - started)
    }

    private func verify(runtime: StorageTransferRuntime,
                        validate: @escaping @MainActor () throws -> Void) async throws {
        guard try runtime.pendingLocalJournal() == nil,
              case let .selected(selection) = PersistenceDeploymentState.load() else {
            throw DevelopmentTransferFailure.precondition
        }
        let urls = try PersistenceStoreTopology.persistentStoreURLs(for: selection.storageLaunchMode,
            accountNamespace: selection.storageNamespace)
        let container = try StorageTransferPersistence.makeContainer(selection: selection, urls: urls, cloudEnabled: false)
        let snapshot = try PomoGemStorageSnapshot.capture(from: ModelContext(container))
        report.sourceRecordCounts = snapshot.recordCounts
        guard let digest = state.expectedDestinationDigest, let cloudOnly = state.expectedDestinationCloudOnly else {
            throw DevelopmentTransferFailure.missingAuditState
        }
        let original = try PomoGemStorageSnapshot.read(from: directory.appendingPathComponent("expected-destination-v1.json"), expectedDigest: digest)
        report.localGraphMatchesFixture = try original.isEquivalent(to: snapshot,
            entities: cloudOnly ? PomoGemStorageSnapshot.cloudModelNames : nil,
            normalizeEmptyRelationships: cloudOnly, dateTolerance: cloudOnly ? 0.001 : 0)
        guard report.localGraphMatchesFixture else { throw DevelopmentTransferFailure.snapshotMismatch }
        let expectedBinding: ActiveAccountLocalBinding?
        if case .cloud(let binding) = selection { expectedBinding = binding } else { expectedBinding = nil }
        let binding = try await AppleAccountBoundaryResolver().resolve(expectedBinding: expectedBinding).binding
        let remote = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: binding, validateTransfer: validate)
        report.serverRecordCounts = remote.snapshot.recordCounts
        report.serverGraphMatchesLocal = try snapshot.isEquivalent(to: remote.snapshot,
            entities: PomoGemStorageSnapshot.cloudModelNames, normalizeEmptyRelationships: true, dateTolerance: 0.001)
        guard report.serverGraphMatchesLocal else { throw DevelopmentTransferFailure.snapshotMismatch }
        report.accountStable = true
        report.disposition = "completeServerGraphEqualsLocal"
    }

    func recordFailure(_ error: Error) {
        report.failureKind = error is CancellationError ? "cancelled" : String(reflecting: type(of: error))
        if let failure = error as? DevelopmentTransferFailure { report.failureKind = failure.rawValue }
        // This enum has no associated payloads, so its case name is safe to
        // retain. Never stringify arbitrary CK/NSError descriptions or values.
        if let failure = error as? StorageTransferRecoveryError { report.failureKind = String(describing: failure) }
        if let cloud = error as? CKError { report.cloudErrorCode = cloud.code.rawValue }
        report.succeeded = false
    }

    @discardableResult func publish() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(report)
        try bytes.write(to: directory.appendingPathComponent("latest-phase.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return bytes
    }
}

/// Counts only public event types and completion states. Record/store IDs,
/// errors, account values, and notifications themselves are never retained.
private final class DevelopmentTransferCloudEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stage = "initializing"
    private var counts: [String: Int] = [:]
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event else { return }
            let type: String
            switch event.type {
            case .setup: type = "setup"
            case .import: type = "import"
            case .export: type = "export"
            @unknown default: type = "unknown"
            }
            let status = event.endDate == nil ? "started" : (event.succeeded ? "succeeded" : "failed")
            self?.record(type + "." + status)
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func setStage(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        stage = value
    }

    func snapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return counts
    }

    private func record(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        counts[stage + "." + key, default: 0] += 1
    }
}

#endif
