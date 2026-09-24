import Foundation
import XCTest
@testable import PomoGem

/// Exercises the real runtime, immutable payload/checkpoint files, journal CAS
/// and durable cleanup queue with only the remote transport replaced. No model
/// container, Apple Account resolver or CloudKit service is opened by these tests.
@MainActor
final class StorageTransferRuntimeCancellationTests: XCTestCase {
    private let account = String(repeating: "a", count: 64)

    private struct Fixture {
        let root: URL
        let store: StorageTransferJournalStore
        let journal: StorageTransferJournal
        let files: StorageTransferStoreFiles
        let checkpoint: StorageTransferStateFile<StorageTransferRuntimeCheckpoint>
        let manifest: StorageTransferRecoveryManifest
        let payload: Data
        let runtime: StorageTransferRuntime
        let cleanup: StorageTransferCleanup
    }

    private func fixture(phase: StorageTransferJournal.Phase = .sourceSaved,
                         recovered: Bool = false) throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeCancellation-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        let sourceRoot = parent.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account))
        var journal = try StorageTransferJournal(choice: .enableCloudReplacingCloud,
            source: .localOnly(namespace: AccountDataNamespace()), destination: .cloud(binding: binding), cloudBinding: binding)
        let files = try StorageTransferStoreFiles(transactionID: journal.transactionID, transferRoot: root, storeDirectory: sourceRoot)
        // Preserve non-canonical but valid recovered bytes to catch accidental
        // reconstruction of a different manifest during cancellation.
        let bytes = Data("{ \"records\" : [], \"formatVersion\" : 1 }\n".utf8)
        let manifest = try StorageTransferRecoveryManifest(transactionID: journal.transactionID,
            accountFingerprint: account, payload: bytes)
        _ = try StorageTransferPayloadStore(files: files).saveRecovered(bytes, manifest: manifest)
        let store = StorageTransferJournalStore(directory: root)
        try store.begin(journal)
        for nextPhase in StorageTransferJournal.Phase.allCases.dropFirst() where nextPhase <= phase {
            if nextPhase == .selectionCommitted { try store.commitSelection(for: journal) }
            let next = try journal.advancing(to: nextPhase,
                sourceDigest: nextPhase == .sourceSaved ? manifest.payloadSHA256 : nil,
                destinationDigest: nextPhase == .destinationSaved ? manifest.payloadSHA256 : nil,
                remoteRecoveryTransactionID: nextPhase == .recoveryCopySaved ? journal.transactionID : nil)
            try store.save(next, replacing: journal)
            journal = next
        }
        var saved = StorageTransferRuntimeCheckpoint(transactionID: journal.transactionID, requestingProcessID: UUID())
        saved.didObserveBaselineControl = true
        saved.recoveredFromServer = recovered
        if recovered { saved.baselineControl = try StorageTransferRecoveryControl(manifest: manifest) }
        if phase >= .recoveryCopySaved { saved.recoveryManifest = manifest }
        if phase >= .preparingDestination {
            saved.importedPayloadDigest = manifest.payloadSHA256
            saved.cloudExportIntentRecorded = true
            saved.verifiedCloudProcessID = UUID()
            saved.verifiedCloudPayloadDigest = manifest.payloadSHA256
        }
        try saved.validate(journal: journal)
        let checkpoint = try StorageTransferStateFile<StorageTransferRuntimeCheckpoint>(
            url: files.transactionDirectory.appendingPathComponent("runtime-v1.json"))
        try checkpoint.save(saved, replacing: nil)
        return Fixture(root: root, store: store, journal: journal, files: files,
            checkpoint: checkpoint, manifest: manifest, payload: bytes,
            runtime: StorageTransferRuntime(store: store, root: root),
            cleanup: try StorageTransferCleanup(featureRoot: root, journalStore: store, validateLocalCleanup: {}))
    }

    private func recovery(_ backend: RuntimeCancellationBackend) -> StorageTransferRemoteRecovery {
        StorageTransferRemoteRecovery(backend: backend, validateAccess: {})
    }

    private struct RetainedFixture {
        let root: URL
        let sourceRoot: URL
        let store: StorageTransferJournalStore
        let journal: StorageTransferJournal
        let files: StorageTransferStoreFiles
        let checkpoint: StorageTransferRuntimeCheckpoint
        let runtime: StorageTransferRuntime
        let cleanup: StorageTransferCleanup
        let source: PomoGemStorageSnapshot
        let cloudAtValidation: PomoGemStorageSnapshot
        let cloudAfterOtherDeviceWrite: PomoGemStorageSnapshot
    }

    /// Valid model DTOs and synthetic artifact families exercise cancellation
    /// without opening SQLite or CloudKit. The staged bytes deliberately differ
    /// from the sealed validation snapshot, just as a late ordinary import can.
    private func retainedFixture(choice: StorageTransferChoice = .enableCloudKeepingCloud,
                                 phase: StorageTransferJournal.Phase = .preparingDestination,
                                 refresh: Bool = false, unsyncedSource: Bool = false) throws -> RetainedFixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("RetainedCancellation-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        let sourceRoot = parent.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account))
        let previous = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account))
        let sourceSelection: PersistenceDeploymentSelection = choice == .disableCloudKeepingCopy
            ? .cloud(binding: binding) : refresh ? .cloud(binding: previous) : .localOnly(namespace: AccountDataNamespace())
        let destination: PersistenceDeploymentSelection = choice == .disableCloudKeepingCopy
            ? .localOnly(namespace: AccountDataNamespace()) : .cloud(binding: binding)
        var journal = try StorageTransferJournal(choice: choice, source: sourceSelection,
            destination: destination, cloudBinding: binding)
        let files = try StorageTransferStoreFiles(transactionID: journal.transactionID, transferRoot: root, storeDirectory: sourceRoot)
        let original = try sessionSnapshot(count: 1)
        let changed = try sessionSnapshot(count: 2)
        let source = unsyncedSource ? changed : original
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let sourceBytes = try encoder.encode(source)
        for url in files.storeURLs(for: sourceSelection, location: .source) { try sourceBytes.write(to: url) }
        _ = try files.freeze(selection: sourceSelection)
        let receipt = try StorageTransferPayloadStore(files: files).save(source)
        let stage = files.transactionDirectory.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        let stagedBytes = try encoder.encode(choice == .disableCloudKeepingCopy ? source : changed)
        for url in files.storeURLs(for: destination, location: .staged) { try stagedBytes.write(to: url) }
        let destinationDigest = choice == .disableCloudKeepingCopy ? receipt.sha256
            : StorageTransferRecoverySchema.digest(try encoder.encode(original))
        if choice == .enableCloudKeepingCloud {
            try StorageTransferStateFile<PomoGemStorageSnapshot>(url: files.transactionDirectory
                .appendingPathComponent("destination-payload-v1.json")).save(original, replacing: nil)
        }
        let store = StorageTransferJournalStore(directory: root)
        try store.begin(journal)
        for nextPhase in StorageTransferJournal.Phase.allCases.dropFirst() where nextPhase <= phase {
            if nextPhase == .selectionCommitted { try store.commitSelection(for: journal) }
            let next = try journal.advancing(to: nextPhase,
                sourceDigest: nextPhase == .sourceSaved ? receipt.sha256 : nil,
                destinationDigest: nextPhase == .destinationSaved ? destinationDigest : nil)
            try store.save(next, replacing: journal)
            journal = next
        }
        var checkpoint = StorageTransferRuntimeCheckpoint(transactionID: journal.transactionID, requestingProcessID: UUID())
        checkpoint.didObserveBaselineControl = true
        if choice == .enableCloudKeepingCloud {
            checkpoint.verifiedCloudProcessID = UUID()
            checkpoint.verifiedCloudPayloadDigest = destinationDigest
        } else {
            checkpoint.importedPayloadDigest = receipt.sha256
        }
        try checkpoint.validate(journal: journal)
        try StorageTransferStateFile<StorageTransferRuntimeCheckpoint>(url: files.transactionDirectory
            .appendingPathComponent("runtime-v1.json")).save(checkpoint, replacing: nil)
        return RetainedFixture(root: root, sourceRoot: sourceRoot, store: store, journal: journal,
            files: files, checkpoint: checkpoint,
            runtime: StorageTransferRuntime(store: store, root: root, storeDirectory: sourceRoot,
                readSourceSelection: { .selected(sourceSelection) }),
            cleanup: try StorageTransferCleanup(featureRoot: root, journalStore: store, validateLocalCleanup: {}),
            source: source, cloudAtValidation: original, cloudAfterOtherDeviceWrite: changed)
    }

    private func sessionSnapshot(count: Int) throws -> PomoGemStorageSnapshot {
        let descriptors = try XCTUnwrap(PomoGemStorageSnapshot.fieldDescriptors["StudySession"])
        let rows = (0..<count).map { index -> PomoGemStorageSnapshot.Record in
            var fields: [String: PomoGemStorageSnapshot.Scalar] = [:]
            for field in descriptors {
                if field.isOptional { fields[field.name] = .null; continue }
                switch field.kind {
                case .string: fields[field.name] = .string("synthetic-day")
                case .integer: fields[field.name] = .integer(0)
                case .boolean: fields[field.name] = .boolean(false)
                case .double: fields[field.name] = .doubleBits(0.0.bitPattern)
                case .date: fields[field.name] = .dateBits(700_000_000.0.bitPattern)
                case .uuid: fields[field.name] = .uuid(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(index + 1))))
                case .data: fields[field.name] = .data(Data())
                }
            }
            fields["source"] = .string(SessionSource.manual.rawValue)
            fields["pebbleKind"] = .string(PebbleKind.normal.rawValue)
            fields["seconds"] = .integer(1_800)
            fields["grams"] = .integer(300)
            fields["endAt"] = .dateBits(700_001_800.0.bitPattern)
            return .init(reference: index, entity: "StudySession", fields: fields, relationships: ["subject": .toOne(nil)])
        }
        let snapshot = PomoGemStorageSnapshot(records: rows)
        try snapshot.validate()
        return snapshot
    }

    private func retainedBytes(_ f: RetainedFixture) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for root in [f.sourceRoot, f.files.transactionDirectory] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[url.path] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private func assertNoRemoteCalls(_ backend: RuntimeCancellationBackend,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(backend.accountChecks, 0, file: file, line: line)
        XCTAssertEqual(backend.controlReads, 0, file: file, line: line)
        XCTAssertEqual(backend.chunkReads, 0, file: file, line: line)
        XCTAssertEqual(backend.receiptReads, 0, file: file, line: line)
        XCTAssertTrue(backend.savedPhases.isEmpty, file: file, line: line)
        XCTAssertEqual(backend.chunkSaves, 0, file: file, line: line)
        XCTAssertEqual(backend.chunkDeletes, 0, file: file, line: line)
    }

    private func expectStale(_ action: () async throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected stale transaction refusal", file: file, line: line) }
        catch { XCTAssertEqual(error as? StorageTransferError, .staleTransaction, file: file, line: line) }
    }

    func testOtherDeviceWriteAfterCloudVerificationCanCancelKeepingEveryImportByte() async throws {
        for phase in [StorageTransferJournal.Phase.preparingDestination, .destinationSaved] {
            let f = try retainedFixture(phase: phase)
            XCTAssertFalse(try f.cloudAtValidation.isEquivalent(to: f.cloudAfterOtherDeviceWrite))
            XCTAssertNotNil(f.checkpoint.verifiedCloudProcessID)
            let before = try retainedBytes(f)
            let backend = RuntimeCancellationBackend(account: account)
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                recovery: recovery(backend), validateAccess: {})
            XCTAssertNil(try f.store.load())
            XCTAssertNil(try f.store.committedSelection())
            XCTAssertEqual(try retainedBytes(f), before)
            XCTAssertTrue(try XCTUnwrap(f.cleanup.pendingReceipts().first).retainsLocalCopies)
            assertNoRemoteCalls(backend)
            // The immutable validation snapshot and later imported session are
            // both retained; cancellation never rewrites one to match the other.
            let validation = try XCTUnwrap(StorageTransferStateFile<PomoGemStorageSnapshot>(url: f.files.transactionDirectory
                .appendingPathComponent("destination-payload-v1.json")).load())
            XCTAssertEqual(validation, f.cloudAtValidation)
            let stageURL = try XCTUnwrap(f.files.storeURLs(for: f.journal.destination, location: .staged).first)
            XCTAssertEqual(try JSONDecoder().decode(PomoGemStorageSnapshot.self, from: Data(contentsOf: stageURL)),
                           f.cloudAfterOtherDeviceWrite)
        }
    }

    func testPublicCancellationOfExplicitRefreshNeedsNoCloudAccountResolver() async throws {
        let f = try retainedFixture(refresh: true)
        let before = try retainedBytes(f)
        // This is the production overload, with no mock account or transport.
        // Its synthetic binding cannot resolve through the live Apple Account.
        try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID, validateAccess: {})
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(try retainedBytes(f), before)
        XCTAssertTrue(try XCTUnwrap(f.cleanup.pendingReceipts().first).retainsLocalCopies)
    }

    func testDisableCancellationPreservesFrozenPendingRowsAndRemoteMismatch() async throws {
        for unsyncedSource in [false, true] {
            for phase in [StorageTransferJournal.Phase.preparingDestination, .destinationSaved] {
                let f = try retainedFixture(choice: .disableCloudKeepingCopy, phase: phase, unsyncedSource: unsyncedSource)
                let remote = unsyncedSource ? f.cloudAtValidation : f.cloudAfterOtherDeviceWrite
                XCTAssertFalse(try f.source.isEquivalent(to: remote), "A frozen source cannot converge by retrying the same comparison")
                let before = try retainedBytes(f)
                let backend = RuntimeCancellationBackend(account: account)
                try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                    recovery: recovery(backend), validateAccess: {})
                XCTAssertNil(try f.store.load())
                XCTAssertNil(try f.store.committedSelection())
                XCTAssertEqual(try retainedBytes(f), before)
                XCTAssertEqual(try StorageTransferPayloadStore(files: f.files).load(expectedDigest: XCTUnwrap(f.journal.sourceDigest)), f.source)
                assertNoRemoteCalls(backend)
            }
        }
    }

    func testDurableRetentionInterruptedBeforeClearIsHonoredByOrdinaryStartupResume() async throws {
        for choice in [StorageTransferChoice.enableCloudKeepingCloud, .disableCloudKeepingCopy] {
            let f = try retainedFixture(choice: choice)
            let before = try retainedBytes(f)
            let backend = RuntimeCancellationBackend(account: account)
            var interrupted = false
            do {
                try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                    recovery: recovery(backend), validateAccess: {
                        if !(try f.cleanup.pendingReceipts()).isEmpty {
                            interrupted = true
                            XCTAssertEqual(try f.store.load(), f.journal)
                            throw CancellationError()
                        }
                    })
                XCTFail("Expected durable retention before interruption")
            } catch is CancellationError { }
            XCTAssertTrue(interrupted)
            XCTAssertEqual(try f.store.load(), f.journal)
            let receipt = try XCTUnwrap(f.cleanup.pendingReceipts().first)
            let restart = StorageTransferRuntime(store: f.store, root: f.root, storeDirectory: f.sourceRoot,
                readSourceSelection: { .selected(f.journal.source) })
            var containers = 0
            let result = try await restart.resumePendingTransfer(validateAccess: {}, trackContainer: { _, _ in containers += 1 })
            XCTAssertEqual(result, .cancelledRetainingImport)
            XCTAssertEqual(containers, 0)
            XCTAssertNil(try f.store.load())
            XCTAssertEqual(try f.cleanup.pendingReceipts(), [receipt])
            try restart.resumeLocalCleanup(validateAccess: {})
            try await restart.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID, validateAccess: {})
            XCTAssertEqual(try retainedBytes(f), before)
            XCTAssertEqual(try f.cleanup.pendingReceipts(), [receipt])
            assertNoRemoteCalls(backend)
        }
    }

    func testStartupRefusesRetentionReceiptForDifferentCheckpointPhase() async throws {
        let f = try retainedFixture()
        _ = try f.cleanup.enqueueCancellation(journal: f.journal, cancelledControl: nil)
        let advanced = try f.journal.advancing(to: .destinationSaved,
            destinationDigest: XCTUnwrap(f.checkpoint.verifiedCloudPayloadDigest))
        try f.store.save(advanced, replacing: f.journal)
        let before = try retainedBytes(f)
        var containers = 0
        await expectStale {
            try await f.runtime.resumePendingTransfer(validateAccess: {}, trackContainer: { _, _ in containers += 1 })
        }
        XCTAssertEqual(containers, 0)
        XCTAssertEqual(try f.store.load(), advanced)
        XCTAssertEqual(try retainedBytes(f), before)
    }

    func testRetainedCancelRequiresOriginalSelectionAndStillSealedSource() async throws {
        let f = try retainedFixture(refresh: true)
        let backend = RuntimeCancellationBackend(account: account)
        let wrongSelection = StorageTransferRuntime(store: f.store, root: f.root, storeDirectory: f.sourceRoot,
            readSourceSelection: { .selected(f.journal.destination) })
        await expectStale {
            try await wrongSelection.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                recovery: self.recovery(backend), validateAccess: {})
        }
        XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
        let original = try XCTUnwrap(f.files.storeURLs(for: f.journal.source, location: .source).first)
        try Data("source changed after frozen checkpoint".utf8).write(to: original)
        let before = try retainedBytes(f)
        do {
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                recovery: recovery(backend), validateAccess: {})
            XCTFail("Changed source cannot be republished from an old checkpoint")
        } catch { XCTAssertEqual(error as? StorageTransferStoreFileError, .changedArtifact) }
        XCTAssertEqual(try f.store.load(), f.journal)
        XCTAssertEqual(try retainedBytes(f), before)
        XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
        assertNoRemoteCalls(backend)
    }

    func testRetainedCancelRefusesDestinationPromotionAndLaterRequests() async throws {
        for choice in [StorageTransferChoice.enableCloudKeepingCloud, .disableCloudKeepingCopy] {
            let f = try retainedFixture(choice: choice, phase: .destinationVerified)
            let backend = RuntimeCancellationBackend(account: account)
            await expectStale {
                try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                    recovery: self.recovery(backend), validateAccess: {})
            }
            XCTAssertEqual(try f.store.load(), f.journal)
            assertNoRemoteCalls(backend)
        }
        let f = try retainedFixture()
        try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID, validateAccess: {})
        let next = try StorageTransferJournal(choice: f.journal.choice, source: f.journal.source,
            destination: f.journal.destination, cloudBinding: f.journal.cloudBinding)
        try f.store.begin(next)
        let before = try retainedBytes(f)
        let backend = RuntimeCancellationBackend(account: account)
        await expectStale {
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                recovery: self.recovery(backend), validateAccess: {})
        }
        XCTAssertEqual(try f.store.load(), next)
        XCTAssertEqual(try retainedBytes(f), before)
        assertNoRemoteCalls(backend)
    }

    func testCommittedDestinationReceiptCannotAuthorizeReturnToClaimedOldSource() async throws {
        let f = try retainedFixture(phase: .destinationSaved)
        let promoted = try f.journal.advancing(to: .destinationVerified)
        let receipt = try StorageTransferCommittedSelection(journal: promoted)
        try StorageTransferStateFile<StorageTransferCommittedSelection>(url: f.root
            .appendingPathComponent("selection-v1.json")).save(receipt, replacing: nil)
        let before = try retainedBytes(f)
        let backend = RuntimeCancellationBackend(account: account)
        await expectStale {
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                recovery: self.recovery(backend), validateAccess: {})
        }
        XCTAssertEqual(try f.store.load(), f.journal)
        XCTAssertEqual(try f.store.committedSelection(), receipt)
        XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
        XCTAssertEqual(try retainedBytes(f), before)
        assertNoRemoteCalls(backend)
    }

    func testRetriedCancellationCannotAcknowledgeARequestCreatedByItsValidationCallback() async throws {
        let f = try retainedFixture()
        try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID, validateAccess: {})
        let next = try StorageTransferJournal(choice: f.journal.choice, source: f.journal.source,
            destination: f.journal.destination, cloudBinding: f.journal.cloudBinding)
        var checks = 0
        await expectStale {
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID, validateAccess: {
                checks += 1
                if checks == 2 { try f.store.begin(next) }
            })
        }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(try f.store.load(), next)
        XCTAssertEqual(try f.cleanup.pendingReceipts().count, 1)
    }

    func testRetainedCancellationAdmissionNeverBypassesProcessMirrorFence() throws {
        let f = try retainedFixture()
        let current = UUID()
        try StorageTransferRetainedCancellationAdmission.validate(journal: f.journal, checkpoint: f.checkpoint,
            currentProcessID: current, cloudMirrorWasOpened: false, selection: .selected(f.journal.source))
        for process in [try XCTUnwrap(f.checkpoint.requestingProcessID), try XCTUnwrap(f.checkpoint.verifiedCloudProcessID)] {
            XCTAssertThrowsError(try StorageTransferRetainedCancellationAdmission.validate(journal: f.journal, checkpoint: f.checkpoint,
                currentProcessID: process, cloudMirrorWasOpened: false, selection: .selected(f.journal.source))) {
                XCTAssertEqual($0 as? StorageTransferRuntimeError, .relaunchRequired)
            }
        }
        XCTAssertThrowsError(try StorageTransferRetainedCancellationAdmission.validate(journal: f.journal, checkpoint: f.checkpoint,
            currentProcessID: current, cloudMirrorWasOpened: true, selection: .selected(f.journal.source))) {
            XCTAssertEqual($0 as? StorageTransferRuntimeError, .relaunchRequired)
        }
    }

    func testUnacknowledgedNilStageCreatesExactCancelledFenceWithoutPayloadUpload() async throws {
        let f = try fixture()
        let backend = RuntimeCancellationBackend(account: account)
        var checkedBeforeCAS = false
        backend.beforeCAS = {
            checkedBeforeCAS = true
            XCTAssertEqual(try f.store.load(), f.journal)
            XCTAssertEqual(try f.checkpoint.load()?.recoveryManifest, f.manifest)
            XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
            XCTAssertEqual(try StorageTransferPayloadStore(files: f.files).bytes(expectedDigest: f.manifest.payloadSHA256), f.payload)
        }
        try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
            recovery: recovery(backend), validateAccess: {})
        XCTAssertTrue(checkedBeforeCAS)
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(backend.savedPhases, [.cancelled])
        XCTAssertEqual(backend.control?.control.manifest, f.manifest)
        XCTAssertEqual(backend.chunkSaves, 0)
        XCTAssertEqual(backend.chunkDeletes, 0)
        let queued = try XCTUnwrap(f.cleanup.pendingReceipts().first)
        XCTAssertEqual(queued.recoveryManifest, f.manifest)
        XCTAssertFalse(queued.localRemoved)
        XCTAssertNil(queued.committedSelection)
        XCTAssertEqual(backend.receipts[f.journal.transactionID]?.phase, .cancelled)
        let delayedStage = try StorageTransferRecoveryControl(manifest: f.manifest)
        do {
            _ = try await backend.compareAndSwapControl(delayedStage, replacing: nil)
            XCTFail("Old nil-baseline staging must lose to the durable cancelled fence")
        } catch { XCTAssertEqual(error as? StorageTransferRecoveryError, .staleControl) }
    }

    func testArchivedOldCancellationClearsLocalJournalWithoutTouchingNewerCommittedTransaction() async throws {
        let f = try fixture()
        let backend = RuntimeCancellationBackend(account: account)
        let remote = recovery(backend)
        _ = try await remote.cancelUnclaimed(manifest: f.manifest)
        let newerBytes = Data("newer synthetic payload".utf8)
        let newer = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account, payload: newerBytes)
        _ = try await remote.stage(manifest: newer, payload: newerBytes, replacingTerminalTransactionID: f.journal.transactionID)
        _ = try await remote.authorizeReplacement(manifest: newer)
        _ = try await remote.commitReplacement(manifest: newer, verifiedDestinationSHA256: newer.payloadSHA256)
        let current = backend.control
        let saved = backend.savedPhases
        let chunks = backend.chunks
        let reads = backend.controlReads
        try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
            recovery: remote, validateAccess: {})
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(backend.control, current)
        XCTAssertEqual(backend.savedPhases, saved)
        XCTAssertEqual(backend.chunks, chunks)
        XCTAssertEqual(backend.controlReads, reads)
        XCTAssertEqual(try f.cleanup.pendingReceipts().first?.recoveryManifest, f.manifest)
    }

    func testRecoveredRequestedPayloadIsAcknowledgedBeforeCancellationAndRetainsOriginalBytes() async throws {
        let f = try fixture(phase: .requested, recovered: true)
        let backend = RuntimeCancellationBackend(account: account)
        backend.control = StorageTransferRecoveryEnvelope(control: try StorageTransferRecoveryControl(manifest: f.manifest),
                                                          changeTag: "recovered-source-control")
        var observedAcknowledgment = false
        backend.onReceiptRead = {
            observedAcknowledgment = true
            XCTAssertEqual(try f.store.load()?.phase, .sourceSaved)
            XCTAssertEqual(try f.store.load()?.sourceDigest, f.manifest.payloadSHA256)
            XCTAssertEqual(try f.checkpoint.load()?.recoveryManifest, f.manifest)
        }
        try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
            recovery: recovery(backend), validateAccess: {})
        XCTAssertTrue(observedAcknowledgment)
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(try Data(contentsOf: f.files.snapshotURL), f.payload)
        let queued = try XCTUnwrap(f.cleanup.pendingReceipts().first)
        guard case let .cancelled(journal, control) = queued.authorization else {
            return XCTFail("Expected a local cancellation authorization")
        }
        XCTAssertEqual(journal.phase, .sourceSaved)
        XCTAssertEqual(control?.manifest, f.manifest)
        XCTAssertEqual(backend.chunkSaves, 0)
    }

    // MARK: transfer-04 — the relaunch screen's 「次に開くと…完了します」

    /// The relaunch screen promises that the next launch completes the
    /// transfer only when that is true: an earlier process verified the staged
    /// mirror, or the journal is already past saving the destination.
    func testTheNextLaunchCompletesOnlyAfterVerificationOrPastTheDestinationSave() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeNoJournal-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: empty) }
        XCTAssertFalse(StorageTransferRuntime(store: StorageTransferJournalStore(directory: empty), root: empty)
            .pendingTransferCompletesOnNextLaunch(), "No journal: nothing to complete")

        for phase in [StorageTransferJournal.Phase.requested, .sourceSaved, .recoveryCopySaved] {
            let f = try fixture(phase: phase)
            XCTAssertNil(try f.checkpoint.load()?.verifiedCloudProcessID, "\(phase)")
            XCTAssertFalse(f.runtime.pendingTransferCompletesOnNextLaunch(),
                "\(phase): nothing was verified yet, so more than one launch may remain")
        }

        let verified = try fixture(phase: .preparingDestination)
        XCTAssertNotNil(try verified.checkpoint.load()?.verifiedCloudProcessID)
        XCTAssertTrue(verified.runtime.pendingTransferCompletesOnNextLaunch(),
            "An earlier process verified the mirror")
        // The same phase without the checkpoint that says so promises nothing.
        try FileManager.default.removeItem(at: verified.files.transactionDirectory
            .appendingPathComponent("runtime-v1.json"))
        XCTAssertFalse(verified.runtime.pendingTransferCompletesOnNextLaunch())

        for phase in [StorageTransferJournal.Phase.destinationSaved, .destinationVerified,
                      .selectionCommitted, .sourceRetired] {
            let f = try fixture(phase: phase)
            try FileManager.default.removeItem(at: f.files.transactionDirectory
                .appendingPathComponent("runtime-v1.json"))
            XCTAssertTrue(f.runtime.pendingTransferCompletesOnNextLaunch(),
                "\(phase): past saving the destination, the phase alone decides")
        }
    }

    func testDestructivePhasesAndWrongTransactionAreRefusedBeforeRemoteCalls() async throws {
        for phase in [StorageTransferJournal.Phase.preparingDestination, .destinationSaved, .sourceRetired] {
            let f = try fixture(phase: phase)
            let backend = RuntimeCancellationBackend(account: account)
            await expectStale {
                try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                    recovery: self.recovery(backend), validateAccess: {})
            }
            XCTAssertEqual(try f.store.load(), f.journal)
            XCTAssertEqual(backend.accountChecks, 0)
            XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
        }
        let f = try fixture()
        let backend = RuntimeCancellationBackend(account: account)
        await expectStale {
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: UUID(), recovery: self.recovery(backend), validateAccess: {})
        }
        XCTAssertEqual(backend.accountChecks, 0)
        XCTAssertEqual(try f.store.load(), f.journal)
    }

    func testJournalRevisionChangingDuringRemoteReadPreventsCancellationCAS() async throws {
        let f = try fixture()
        let backend = RuntimeCancellationBackend(account: account)
        let advanced = try f.journal.advancing(to: .recoveryCopySaved, remoteRecoveryTransactionID: f.journal.transactionID)
        backend.onReceiptRead = { try f.store.save(advanced, replacing: f.journal) }
        await expectStale {
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                recovery: self.recovery(backend), validateAccess: {})
        }
        XCTAssertEqual(try f.store.load(), advanced)
        XCTAssertTrue(backend.savedPhases.isEmpty)
        XCTAssertNil(backend.control)
        XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
    }

    func testEntireJournalReplacedDuringRemoteReadNeverClearsOrCancelsNewTransaction() async throws {
        let f = try fixture()
        let backend = RuntimeCancellationBackend(account: account)
        let next = try StorageTransferJournal(choice: f.journal.choice, source: f.journal.source,
            destination: f.journal.destination, cloudBinding: f.journal.cloudBinding)
        backend.onReceiptRead = {
            try f.store.cancel(f.journal)
            try f.store.begin(next)
        }
        await expectStale {
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                recovery: self.recovery(backend), validateAccess: {})
        }
        XCTAssertEqual(try f.store.load(), next)
        XCTAssertTrue(backend.savedPhases.isEmpty)
        XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
    }

    func testQueueIsDurableBeforeJournalClearAndInterruptedFinalClearCanRetry() async throws {
        let f = try fixture()
        let backend = RuntimeCancellationBackend(account: account)
        var interrupted = false
        do {
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                recovery: recovery(backend), validateAccess: {
                    if !interrupted, !(try f.cleanup.pendingReceipts()).isEmpty {
                        interrupted = true
                        XCTAssertEqual(try f.store.load(), f.journal)
                        throw CancellationError()
                    }
                })
            XCTFail("Expected interruption after durable queue and before journal removal")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(interrupted)
        XCTAssertEqual(try f.store.load(), f.journal)
        XCTAssertEqual(try f.cleanup.pendingReceipts().first?.recoveryManifest, f.manifest)
        let restart = StorageTransferRuntime(store: f.store, root: f.root)
        try await restart.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
            recovery: recovery(backend), validateAccess: {})
        XCTAssertNil(try f.store.load())
        XCTAssertEqual(backend.savedPhases, [.cancelled])
        XCTAssertEqual(try f.cleanup.pendingReceipts().count, 1)
    }

    func testQueueWriteFailureKeepsJournalAndPayloadAfterAcknowledgedRemoteCancellation() async throws {
        let f = try fixture()
        let backend = RuntimeCancellationBackend(account: account)
        let unknown = f.files.transactionDirectory.appendingPathComponent("unknown-user-file")
        let protected = Data("synthetic unknown file".utf8)
        try protected.write(to: unknown)
        do {
            try await f.runtime.cancelPendingTransfer(expectedTransactionID: f.journal.transactionID,
                recovery: recovery(backend), validateAccess: {})
            XCTFail("Unknown artifact must prevent cleanup authorization")
        } catch { XCTAssertEqual(error as? StorageTransferCleanupError, .unknownArtifact) }
        XCTAssertEqual(backend.control?.control.phase, .cancelled)
        XCTAssertEqual(try f.store.load(), f.journal)
        XCTAssertEqual(try Data(contentsOf: f.files.snapshotURL), f.payload)
        XCTAssertEqual(try Data(contentsOf: unknown), protected)
        XCTAssertTrue(try f.cleanup.pendingReceipts().isEmpty)
    }
}

@MainActor
private final class RuntimeCancellationBackend: StorageTransferRecoveryBackend {
    let account: String
    var accountChecks = 0
    var controlReads = 0
    var chunkReads = 0
    var receiptReads = 0
    var control: StorageTransferRecoveryEnvelope?
    var receipts: [UUID: StorageTransferRecoveryControl] = [:]
    var chunks: [String: StorageTransferRecoveryChunk] = [:]
    var savedPhases: [StorageTransferRecoveryControl.Phase] = []
    var chunkSaves = 0
    var chunkDeletes = 0
    var onReceiptRead: (() throws -> Void)?
    var beforeCAS: (() throws -> Void)?
    private var version = 0

    init(account: String) { self.account = account }
    func verifyAccount(_ fingerprint: String) async throws {
        accountChecks += 1
        guard fingerprint == account else { throw StorageTransferRecoveryError.identityMismatch }
    }
    func readControl() async throws -> StorageTransferRecoveryEnvelope? {
        controlReads += 1
        return control
    }
    func compareAndSwapControl(_ next: StorageTransferRecoveryControl,
                               replacing previous: StorageTransferRecoveryEnvelope?) async throws -> StorageTransferRecoveryEnvelope {
        let hook = beforeCAS; beforeCAS = nil; try hook?()
        guard control == previous else { throw StorageTransferRecoveryError.staleControl }
        try next.validate()
        version += 1
        let result = StorageTransferRecoveryEnvelope(control: next, changeTag: "synthetic-cancellation-\(version)")
        control = result
        savedPhases.append(next.phase)
        return result
    }
    func readChunk(manifest: StorageTransferRecoveryManifest, index: Int) async throws -> StorageTransferRecoveryChunk? {
        chunkReads += 1
        return chunks["chunk-\(manifest.transactionID.uuidString.lowercased())-\(index)"]
    }
    func saveChunkIfAbsent(_ chunk: StorageTransferRecoveryChunk) async throws {
        if let previous = chunks[chunk.recordName], previous != chunk { throw StorageTransferRecoveryError.corruptChunk }
        chunkSaves += 1
        chunks[chunk.recordName] = chunk
    }
    func retainTerminalReceipt(_ value: StorageTransferRecoveryControl) async throws {
        try value.validate()
        guard value.isTerminal else { throw StorageTransferRecoveryError.invalidControl }
        if let previous = receipts[value.manifest.transactionID], previous != value { throw StorageTransferRecoveryError.staleControl }
        receipts[value.manifest.transactionID] = value
    }
    func readTerminalReceipt(transactionID: UUID) async throws -> StorageTransferRecoveryControl? {
        receiptReads += 1
        let hook = onReceiptRead; onReceiptRead = nil; try hook?()
        return receipts[transactionID]
    }
    func deleteChunkIfMatches(_ chunk: StorageTransferRecoveryChunk,
                              terminalReceipt: StorageTransferRecoveryControl) async throws {
        guard terminalReceipt.isTerminal, receipts[terminalReceipt.manifest.transactionID] == terminalReceipt,
              chunks[chunk.recordName] == chunk else { throw StorageTransferRecoveryError.staleControl }
        chunkDeletes += 1
        chunks.removeValue(forKey: chunk.recordName)
    }
}
