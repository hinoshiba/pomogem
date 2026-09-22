import Foundation
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferCleanupTests: XCTestCase {
    private let account = String(repeating: "a", count: 64)
    private let userBytes = Data("synthetic private payload must not enter cleanup queue".utf8)

    private struct Fixture {
        let root: URL
        let transaction: URL
        let store: StorageTransferJournalStore
        let journal: StorageTransferJournal
        let manifest: StorageTransferRecoveryManifest?
        let sourceStore: URL
    }

    private func fixture(replacesCloud: Bool = false, refreshingCloud: Bool = false, keepingCloud: Bool = false,
                         stoppingAt: StorageTransferJournal.Phase = .sourceRetired) throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("CleanupTests-\(UUID())")
        let root = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account))
        let local = PersistenceDeploymentSelection.localOnly(namespace: AccountDataNamespace())
        let cloud = PersistenceDeploymentSelection.cloud(binding: binding)
        let previousCloud = PersistenceDeploymentSelection.cloud(binding: try XCTUnwrap(
            ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account)))
        var journal = try StorageTransferJournal(choice: refreshingCloud || keepingCloud ? .enableCloudKeepingCloud
                : replacesCloud ? .enableCloudReplacingCloud : .disableCloudKeepingCopy,
            source: refreshingCloud ? previousCloud : replacesCloud || keepingCloud ? local : cloud,
            destination: refreshingCloud || replacesCloud || keepingCloud ? cloud : local, cloudBinding: binding)
        let manifest = replacesCloud ? try StorageTransferRecoveryManifest(transactionID: journal.transactionID,
            accountFingerprint: account, payload: userBytes) : nil
        let digest = StorageTransferRecoverySchema.digest(userBytes)
        let store = StorageTransferJournalStore(directory: root)
        try store.begin(journal)
        for phase in StorageTransferJournal.Phase.allCases.dropFirst() where phase <= stoppingAt {
            if phase == .selectionCommitted { try store.commitSelection(for: journal) }
            let next = try journal.advancing(to: phase,
                sourceDigest: phase == .sourceSaved ? digest : nil,
                destinationDigest: phase == .destinationSaved ? digest : nil,
                remoteRecoveryTransactionID: phase == .recoveryCopySaved && replacesCloud ? journal.transactionID : nil)
            try store.save(next, replacing: journal)
            journal = next
        }
        let transaction = root.appendingPathComponent(journal.transactionID.uuidString.lowercased(), isDirectory: true)
        let frozen = transaction.appendingPathComponent("frozen", isDirectory: true)
        try FileManager.default.createDirectory(at: frozen, withIntermediateDirectories: true)
        let sourceStore: URL
        switch journal.source {
        case .cloud(let binding): sourceStore = PersistenceStoreTopology.accountStoreURLs(accountNamespace: binding.namespace, directory: frozen)[0]
        case .localOnly(let namespace): sourceStore = PersistenceStoreTopology.localOnlyPersistentStoreURLs(namespace: namespace, directory: frozen)[0]
        }
        try userBytes.write(to: sourceStore)
        try userBytes.write(to: transaction.appendingPathComponent("payload-v1.json"))
        try userBytes.write(to: transaction.appendingPathComponent("destination-payload-v1.json"))
        try Data("{}".utf8).write(to: transaction.appendingPathComponent("runtime-v1.json"))
        return Fixture(root: root, transaction: transaction, store: store, journal: journal,
                       manifest: manifest, sourceStore: sourceStore)
    }

    private func cleanup(_ f: Fixture, validate: @escaping () throws -> Void = {}) throws -> StorageTransferCleanup {
        try StorageTransferCleanup(featureRoot: f.root, journalStore: f.store, validateLocalCleanup: validate)
    }

    func testQueueIsDurableAndMinimalBeforeJournalFinishOrAnyLocalDeletion() throws {
        let f = try fixture()
        let cleaner = try cleanup(f)
        let receipt = try cleaner.enqueue(journal: f.journal, recoveryManifest: nil)
        XCTAssertEqual(receipt.committedSelection, try f.store.committedSelection())
        XCTAssertEqual(try cleaner.enqueue(journal: f.journal, recoveryManifest: nil), receipt)
        XCTAssertThrowsError(try cleaner.runLocal(transactionID: f.journal.transactionID)) {
            XCTAssertEqual($0 as? StorageTransferCleanupError, .journalStillPending)
        }
        XCTAssertEqual(try Data(contentsOf: f.sourceStore), userBytes)
        let queue = f.root.appendingPathComponent("cleanup-\(f.journal.transactionID.uuidString.lowercased()).json")
        let text = try String(contentsOf: queue, encoding: .utf8)
        XCTAssertFalse(text.contains(String(decoding: userBytes, as: UTF8.self)))
        XCTAssertFalse(text.contains(f.root.path))
        XCTAssertEqual(try cleaner.pendingReceipts(), [receipt])
    }

    func testCompleteLocalCleanupRemovesOnlyExactTransactionAndLeavesCurrentSelection() throws {
        let f = try fixture()
        let other = f.root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let protected = other.appendingPathComponent("payload-v1.json")
        try userBytes.write(to: protected)
        let cleaner = try cleanup(f)
        _ = try cleaner.enqueue(journal: f.journal, recoveryManifest: nil)
        try f.store.finish(f.journal)
        try cleaner.runLocal(transactionID: f.journal.transactionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.transaction.path))
        XCTAssertEqual(try Data(contentsOf: protected), userBytes)
        XCTAssertEqual(try f.store.committedSelection(), try StorageTransferCommittedSelection(journal: f.journal))
        XCTAssertTrue(try cleaner.pendingReceipts().isEmpty)
        try cleaner.runLocal(transactionID: f.journal.transactionID)
    }

    func testActualFrameworkAssetDirectoriesAndRecordedUUIDReadersAreRemoved() throws {
        let f = try fixture()
        let stem = f.sourceStore.deletingPathExtension().lastPathComponent
        for name in [stem + "_ckAssets", "." + stem + "_SUPPORT"] {
            let directory = f.sourceStore.deletingLastPathComponent().appendingPathComponent(name).appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try userBytes.write(to: directory.appendingPathComponent("asset.bin"))
        }
        let readerName = UUID().uuidString.lowercased()
        let reader = f.transaction.appendingPathComponent("reader/" + readerName)
        try FileManager.default.createDirectory(at: reader, withIntermediateDirectories: true)
        try userBytes.write(to: reader.appendingPathComponent(f.sourceStore.lastPathComponent))
        let cleaner = try cleanup(f)
        let receipt = try cleaner.enqueue(journal: f.journal, recoveryManifest: nil)
        XCTAssertTrue(receipt.ownedDirectories.contains("reader/" + readerName))
        try f.store.finish(f.journal)
        try cleaner.runLocal(transactionID: f.journal.transactionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.transaction.path))
    }

    func testCloudGenerationRefreshCleansOldCacheTemporaryCopiesWithoutRemotePayload() throws {
        let f = try fixture(refreshingCloud: true)
        for name in ["source-retirement-v1.json", "staged-discard-v1.json"] {
            try Data("{}".utf8).write(to: f.transaction.appendingPathComponent(name))
        }
        let cleaner = try cleanup(f)
        let receipt = try cleaner.enqueue(journal: f.journal, recoveryManifest: nil)
        XCTAssertNil(receipt.recoveryManifest)
        XCTAssertTrue(receipt.remoteRemoved)
        XCTAssertNotEqual(receipt.source?.storageNamespace, receipt.committedSelection?.selection.storageNamespace)
        try f.store.finish(f.journal)
        try cleaner.runLocal(transactionID: f.journal.transactionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.transaction.path))
        XCTAssertEqual(try f.store.committedSelection()?.selection, f.journal.destination)
        XCTAssertTrue(try cleaner.pendingReceipts().isEmpty)
    }

    func testUnknownTopLevelForeignNamespaceAndLateReaderBlockBeforeAnyUnlink() throws {
        for problem in 0..<3 {
            let f = try fixture()
            let cleaner = try cleanup(f)
            _ = try cleaner.enqueue(journal: f.journal, recoveryManifest: nil)
            switch problem {
            case 0: try userBytes.write(to: f.transaction.appendingPathComponent("unrecognized-file"))
            case 1: try userBytes.write(to: f.sourceStore.deletingLastPathComponent().appendingPathComponent("unrelated.store"))
            default:
                let late = f.transaction.appendingPathComponent("reader/" + UUID().uuidString.lowercased())
                try FileManager.default.createDirectory(at: late, withIntermediateDirectories: true)
                try userBytes.write(to: late.appendingPathComponent(f.sourceStore.lastPathComponent))
            }
            try f.store.finish(f.journal)
            XCTAssertThrowsError(try cleaner.runLocal(transactionID: f.journal.transactionID))
            XCTAssertEqual(try Data(contentsOf: f.sourceStore), userBytes)
            XCTAssertEqual(try Data(contentsOf: f.transaction.appendingPathComponent("payload-v1.json")), userBytes)
            XCTAssertEqual(try cleaner.pendingReceipts().count, 1)
        }
    }

    func testNestedSymlinkIsRejectedBeforeDeletingOtherKnownArtifacts() throws {
        let f = try fixture()
        let cleaner = try cleanup(f)
        _ = try cleaner.enqueue(journal: f.journal, recoveryManifest: nil)
        let assets = f.sourceStore.deletingPathExtension().appendingPathExtension("store.ckAssetFiles")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: assets.appendingPathComponent("outside"), withDestinationURL: f.root)
        try f.store.finish(f.journal)
        XCTAssertThrowsError(try cleaner.runLocal(transactionID: f.journal.transactionID))
        XCTAssertEqual(try Data(contentsOf: f.sourceStore), userBytes)
    }

    func testInterruptedUnlinkResumesFromRemainingAuthorizedSubset() throws {
        let f = try fixture()
        var checks = 0
        let cleaner = try cleanup(f) {
            checks += 1
            if checks == 3 { throw StorageTransferCleanupError.staleReceipt }
        }
        _ = try cleaner.enqueue(journal: f.journal, recoveryManifest: nil)
        try f.store.finish(f.journal)
        XCTAssertThrowsError(try cleaner.runLocal(transactionID: f.journal.transactionID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.transaction.path))
        XCTAssertEqual(try cleaner.pendingReceipts().count, 1)
        try cleaner.runLocal(transactionID: f.journal.transactionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.transaction.path))
        XCTAssertTrue(try cleaner.pendingReceipts().isEmpty)
    }

    func testMissingAlreadyUnlinkedDirectoryCompletesReceiptOnRetry() throws {
        let f = try fixture()
        let cleaner = try cleanup(f)
        _ = try cleaner.enqueue(journal: f.journal, recoveryManifest: nil)
        try f.store.finish(f.journal)
        try FileManager.default.removeItem(at: f.transaction)
        try cleaner.runLocal(transactionID: f.journal.transactionID)
        XCTAssertTrue(try cleaner.pendingReceipts().isEmpty)
    }

    func testWrongRootAndForgedManifestCannotAuthorizeCleanup() throws {
        let f = try fixture(replacesCloud: true)
        XCTAssertThrowsError(try StorageTransferCleanup(featureRoot: f.transaction, journalStore: f.store, validateLocalCleanup: {}))
        let cleaner = try cleanup(f)
        XCTAssertThrowsError(try cleaner.enqueue(journal: f.journal, recoveryManifest: nil))
        let wrong = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account, payload: userBytes)
        XCTAssertThrowsError(try cleaner.enqueue(journal: f.journal, recoveryManifest: wrong))
        XCTAssertTrue(try cleaner.pendingReceipts().isEmpty)
        XCTAssertEqual(try Data(contentsOf: f.sourceStore), userBytes)
    }

    private func remote(_ f: Fixture) async throws -> (StorageTransferRemoteRecovery, CleanupRemoteFake) {
        let backend = CleanupRemoteFake(account: account)
        let recovery = StorageTransferRemoteRecovery(backend: backend, validateAccess: {})
        let manifest = try XCTUnwrap(f.manifest)
        _ = try await recovery.stage(manifest: manifest, payload: userBytes)
        _ = try await recovery.authorizeReplacement(manifest: manifest)
        _ = try await recovery.commitReplacement(manifest: manifest, verifiedDestinationSHA256: manifest.payloadSHA256)
        return (recovery, backend)
    }

    func testRemoteNetworkFailureKeepsManifestAfterLocalPayloadRemovalThenRetries() async throws {
        let f = try fixture(replacesCloud: true)
        let cleaner = try cleanup(f)
        _ = try cleaner.enqueue(journal: f.journal, recoveryManifest: f.manifest)
        try f.store.finish(f.journal)
        try cleaner.runLocal(transactionID: f.journal.transactionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.transaction.path))
        let (recovery, backend) = try await remote(f)
        backend.failDeletes = true
        let first = try await cleaner.retryRemoteCleanup(expectedBinding: f.journal.cloudBinding,
                                                         recovery: recovery, validateAccess: {})
        XCTAssertEqual(first.failed, 1)
        XCTAssertEqual(first.completed, 0)
        let queued = try XCTUnwrap(cleaner.pendingReceipts().first)
        XCTAssertTrue(queued.localRemoved)
        XCTAssertFalse(queued.remoteRemoved)
        XCTAssertEqual(queued.recoveryManifest, f.manifest)
        backend.failDeletes = false
        let second = try await cleaner.retryRemoteCleanup(expectedBinding: f.journal.cloudBinding,
                                                          recovery: recovery, validateAccess: {})
        XCTAssertEqual(second.completed, 1)
        XCTAssertEqual(try cleaner.pendingReceipts().count, 1)
        XCTAssertEqual(try cleaner.pendingReceipts().first?.remoteRemoved, true)
        XCTAssertTrue(backend.chunks.isEmpty)
        XCTAssertNotNil(backend.receipts[f.journal.transactionID])
    }

    func testOtherAccountIsSkippedWithoutAnyRemoteCallAndSameAccountNewNamespaceRetries() async throws {
        let f = try fixture(replacesCloud: true)
        let cleaner = try cleanup(f)
        _ = try cleaner.enqueue(journal: f.journal, recoveryManifest: f.manifest)
        try f.store.finish(f.journal)
        let (recovery, backend) = try await remote(f)
        let before = backend.verifications
        let other = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                           accountFingerprint: String(repeating: "b", count: 64)))
        let skipped = try await cleaner.retryRemoteCleanup(expectedBinding: other, recovery: recovery, validateAccess: {})
        XCTAssertEqual(skipped.skippedOtherAccount, 1)
        XCTAssertEqual(backend.verifications, before)
        let same = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: account))
        let completed = try await cleaner.retryRemoteCleanup(expectedBinding: same, recovery: recovery, validateAccess: {})
        XCTAssertEqual(completed.completed, 1)
        XCTAssertEqual(try cleaner.pendingReceipts().first?.remoteRemoved, true)
        try cleaner.runLocal(transactionID: f.journal.transactionID)
        XCTAssertEqual(try cleaner.pendingReceipts().count, 1)
        XCTAssertEqual(try cleaner.pendingReceipts().first?.localRemoved, true)
    }

    func testLateChunkIsRemovedAfterSuccessfulCleanupAndControlAdvancesToAnotherTransaction() async throws {
        let f = try fixture(replacesCloud: true)
        let cleaner = try cleanup(f)
        _ = try cleaner.enqueue(journal: f.journal, recoveryManifest: f.manifest)
        try f.store.finish(f.journal)
        try cleaner.runLocal(transactionID: f.journal.transactionID)
        let (recovery, backend) = try await remote(f)
        let first = try await cleaner.retryRemoteCleanup(expectedBinding: f.journal.cloudBinding,
            recovery: recovery, validateAccess: {})
        XCTAssertEqual(first.completed, 1)
        let oldManifest = try XCTUnwrap(f.manifest)
        let newerPayload = Data("another synthetic transaction".utf8)
        let newer = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account,
            payload: newerPayload, previousDatasetGenerationID: oldManifest.transactionID)
        _ = try await recovery.stage(manifest: newer, payload: newerPayload,
                                     replacingTerminalTransactionID: oldManifest.transactionID)
        let newerControl = backend.control
        let late = try oldManifest.chunk(0, from: userBytes)
        backend.chunks[late.recordName] = late
        // A new coordinator instance models the next launch, with no old local
        // payload or original control-v1 to rediscover the transaction from.
        let restarted = try cleanup(f)
        let result = try await restarted.retryRemoteCleanup(expectedBinding: f.journal.cloudBinding,
                                                             recovery: recovery, validateAccess: {})
        XCTAssertEqual(result.completed, 1)
        XCTAssertNil(backend.chunks[late.recordName])
        XCTAssertEqual(backend.control, newerControl)
        XCTAssertNotNil(backend.chunks[try newer.chunk(0, from: newerPayload).recordName])
        XCTAssertEqual(try restarted.pendingReceipts().first?.remoteAttemptCount, 2)
        XCTAssertEqual(try restarted.pendingReceipts().first?.recoveryManifest, oldManifest)
    }

    private func addHistoricalReceipt(_ original: StorageTransferCleanupReceipt, root: URL) throws -> StorageTransferCleanupReceipt {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        let id = UUID()
        json["transactionID"] = id.uuidString
        var selection = try XCTUnwrap(json["committedSelection"] as? [String: Any])
        selection["transactionID"] = id.uuidString
        json["committedSelection"] = selection
        var manifest = try XCTUnwrap(json["recoveryManifest"] as? [String: Any])
        manifest["transactionID"] = id.uuidString
        json["recoveryManifest"] = manifest
        let result = try JSONDecoder().decode(StorageTransferCleanupReceipt.self,
            from: JSONSerialization.data(withJSONObject: json))
        try result.validate()
        try encoder.encode(result).write(to: root.appendingPathComponent("cleanup-\(id.uuidString.lowercased()).json"))
        return result
    }

    func testBoundedRetryRotatesAfterFailuresAndRechecksAlreadySuccessfulReceipts() async throws {
        let f = try fixture(replacesCloud: true)
        let cleaner = try cleanup(f)
        _ = try cleaner.enqueue(journal: f.journal, recoveryManifest: f.manifest)
        try f.store.finish(f.journal)
        try cleaner.runLocal(transactionID: f.journal.transactionID)
        let original = try XCTUnwrap(cleaner.pendingReceipts().first)
        let older = try addHistoricalReceipt(original, root: f.root)
        let olderManifest = try XCTUnwrap(older.recoveryManifest)
        let (recovery, backend) = try await remote(f)
        backend.receipts[older.transactionID] = try StorageTransferRecoveryControl(manifest: olderManifest)
            .advancing(to: .backupVerified).advancing(to: .replacing)
            .advancing(to: .committed, verifiedDestinationSHA256: olderManifest.payloadSHA256)
        let chunk = try olderManifest.chunk(0, from: userBytes)
        backend.chunks[chunk.recordName] = chunk
        backend.failDeletes = true
        for _ in 0..<2 {
            let result = try await cleaner.retryRemoteCleanup(expectedBinding: f.journal.cloudBinding,
                recovery: recovery, batchLimit: 1, validateAccess: {})
            XCTAssertEqual(result.failed, 1)
            XCTAssertEqual(result.deferred, 1)
        }
        XCTAssertEqual(try cleaner.pendingReceipts().map(\.remoteAttemptCount), [1, 1])
        backend.failDeletes = false
        let complete = try await cleaner.retryRemoteCleanup(expectedBinding: f.journal.cloudBinding,
            recovery: recovery, validateAccess: {})
        XCTAssertEqual(complete.completed, 2)
        XCTAssertTrue(try cleaner.pendingReceipts().allSatisfy(\.remoteRemoved))
        let again = try await cleaner.retryRemoteCleanup(expectedBinding: f.journal.cloudBinding,
            recovery: recovery, batchLimit: 1, validateAccess: {})
        XCTAssertEqual(again.completed, 1)
        XCTAssertEqual(again.deferred, 1)
        XCTAssertEqual(try cleaner.pendingReceipts().map(\.remoteAttemptCount).sorted(), [2, 3])
    }

    func testRetentionBoundBlocksNewRemoteTransferWithoutEvictingAnyTerminalIdentity() throws {
        let f = try fixture(replacesCloud: true)
        let cleaner = try cleanup(f)
        let receipt = try cleaner.enqueue(journal: f.journal, recoveryManifest: f.manifest)
        for _ in 1..<StorageTransferCleanup.maximumRetainedRemoteReceipts {
            _ = try addHistoricalReceipt(receipt, root: f.root)
        }
        XCTAssertThrowsError(try cleaner.requireCapacityForNewTransfer(transactionID: UUID(), mayCreateRemotePayload: true)) {
            XCTAssertEqual($0 as? StorageTransferCleanupError, .limitExceeded)
        }
        try cleaner.requireCapacityForNewTransfer(transactionID: f.journal.transactionID, mayCreateRemotePayload: true)
        try cleaner.requireCapacityForNewTransfer(transactionID: UUID(), mayCreateRemotePayload: false)
        XCTAssertEqual(try cleaner.pendingReceipts().count, StorageTransferCleanup.maximumRetainedRemoteReceipts)
        XCTAssertEqual(try Data(contentsOf: f.sourceStore), userBytes)
    }

    func testLocalCancellationCleansOnlyTemporaryCopiesAfterJournalCancellation() throws {
        let f = try fixture(stoppingAt: .sourceSaved)
        let activeSource = f.root.deletingLastPathComponent().appendingPathComponent(f.sourceStore.lastPathComponent)
        try userBytes.write(to: activeSource)
        let cleaner = try cleanup(f)
        let receipt = try cleaner.enqueueCancellation(journal: f.journal, cancelledControl: nil)
        XCTAssertNil(receipt.committedSelection)
        XCTAssertNil(receipt.recoveryManifest)
        XCTAssertEqual(try cleaner.enqueueCancellation(journal: f.journal, cancelledControl: nil), receipt)
        XCTAssertThrowsError(try cleaner.runLocal(transactionID: f.journal.transactionID))
        try f.store.cancel(f.journal)
        try cleaner.runLocal(transactionID: f.journal.transactionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.transaction.path))
        XCTAssertEqual(try Data(contentsOf: activeSource), userBytes)
        XCTAssertNil(try f.store.committedSelection())
        XCTAssertTrue(try cleaner.pendingReceipts().isEmpty)
    }

    func testLateImportCancellationRetainsEveryCopyAcrossRestartAndNeverCallsRemoteCleanup() async throws {
        for mode in 0..<3 {
            for phase in [StorageTransferJournal.Phase.preparingDestination, .destinationSaved] {
                let f = try fixture(refreshingCloud: mode == 2, keepingCloud: mode == 1, stoppingAt: phase)
                let staged = f.transaction.appendingPathComponent("staged", isDirectory: true)
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
                let stagedStore: URL
                switch f.journal.destination {
                case .cloud(let binding):
                    stagedStore = PersistenceStoreTopology.accountStoreURLs(accountNamespace: binding.namespace, directory: staged)[0]
                case .localOnly(let namespace):
                    stagedStore = PersistenceStoreTopology.localOnlyPersistentStoreURLs(namespace: namespace, directory: staged)[0]
                }
                let importedBytes = Data("new imported data absent from the frozen source".utf8)
                try importedBytes.write(to: stagedStore)
                let assets = staged.appendingPathComponent(stagedStore.deletingPathExtension().lastPathComponent + "_ckAssets/nested")
                try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
                try importedBytes.write(to: assets.appendingPathComponent("asset.bin"))
                let reader = f.transaction.appendingPathComponent("reader/" + UUID().uuidString.lowercased())
                try FileManager.default.createDirectory(at: reader, withIntermediateDirectories: true)
                try importedBytes.write(to: reader.appendingPathComponent(stagedStore.lastPathComponent))
                let activeSource = f.root.deletingLastPathComponent().appendingPathComponent(f.sourceStore.lastPathComponent)
                try userBytes.write(to: activeSource)
                let foreign = f.root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
                try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
                try importedBytes.write(to: foreign.appendingPathComponent("payload-v1.json"))
                let before = try treeBytes(f.transaction)
                let cleaner = try cleanup(f)
                let receipt = try cleaner.enqueueCancellation(journal: f.journal, cancelledControl: nil)
                XCTAssertTrue(receipt.retainsLocalCopies)
                XCTAssertFalse(receipt.localRemoved)
                XCTAssertFalse(receipt.isComplete)
                XCTAssertNil(receipt.recoveryManifest)
                XCTAssertThrowsError(try receipt.recordingLocalRemoval())
                XCTAssertEqual(try cleaner.enqueueCancellation(journal: f.journal, cancelledControl: nil), receipt)
                try cleaner.runLocal(transactionID: f.journal.transactionID)
                XCTAssertEqual(try f.store.load(), f.journal)
                XCTAssertEqual(try treeBytes(f.transaction), before)
                try f.store.cancel(f.journal)

                let queue = f.root.appendingPathComponent("cleanup-\(f.journal.transactionID.uuidString.lowercased()).json")
                let queueBytes = try Data(contentsOf: queue)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: queue.path)
                let restarted = try cleanup(f)
                for _ in 0..<2 { try restarted.runLocal(transactionID: f.journal.transactionID) }
                let backend = CleanupRemoteFake(account: account)
                let result = try await restarted.retryRemoteCleanup(expectedBinding: f.journal.cloudBinding,
                    recovery: StorageTransferRemoteRecovery(backend: backend, validateAccess: {}), validateAccess: {})
                XCTAssertEqual(result, StorageTransferCleanupRetryResult())
                XCTAssertEqual(backend.verifications, 0)
                XCTAssertNil(backend.control)
                XCTAssertEqual(try restarted.retainedCancellationJournal(transactionID: f.journal.transactionID), f.journal)
                XCTAssertEqual(try restarted.pendingReceipts(), [receipt])
                XCTAssertEqual(try Data(contentsOf: queue), queueBytes)
                XCTAssertEqual(try treeBytes(f.transaction), before)
                XCTAssertEqual(try Data(contentsOf: activeSource), userBytes)
                XCTAssertEqual(try Data(contentsOf: foreign.appendingPathComponent("payload-v1.json")), importedBytes)
                XCTAssertNil(try f.store.load())
                XCTAssertNil(try f.store.committedSelection())
            }
        }
    }

    func testRetainedCancellationCannotBeForgedIntoTheEarlyCancellationDeletionGrant() throws {
        for keepingCloud in [false, true] {
            let f = try fixture(keepingCloud: keepingCloud, stoppingAt: .preparingDestination)
            let cleaner = try cleanup(f)
            let receipt = try cleaner.enqueueCancellation(journal: f.journal, cancelledControl: nil)
            let encoder = JSONEncoder()
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(receipt)) as? [String: Any])
            let journal = try JSONSerialization.jsonObject(with: encoder.encode(f.journal))
            json["authorization"] = ["cancelled": ["journal": journal, "control": NSNull()]]
            let forgedBytes = try JSONSerialization.data(withJSONObject: json)
            let forged = try JSONDecoder().decode(StorageTransferCleanupReceipt.self, from: forgedBytes)
            XCTAssertThrowsError(try forged.validate())
            try forgedBytes.write(to: f.root.appendingPathComponent("cleanup-\(f.journal.transactionID.uuidString.lowercased()).json"))
            let before = try treeBytes(f.transaction)
            XCTAssertThrowsError(try cleaner.runLocal(transactionID: f.journal.transactionID))
            XCTAssertEqual(try treeBytes(f.transaction), before)
            XCTAssertEqual(try f.store.load(), f.journal)
        }
        for phase in [StorageTransferJournal.Phase.destinationVerified, .selectionCommitted, .sourceRetired] {
            for keepingCloud in [false, true] {
                let f = try fixture(keepingCloud: keepingCloud, stoppingAt: phase)
                XCTAssertThrowsError(try cleanup(f).enqueueCancellation(journal: f.journal, cancelledControl: nil))
                XCTAssertEqual(try Data(contentsOf: f.sourceStore), userBytes)
            }
        }
    }

    func testRetainedImportDoesNotBlockUnrelatedLegitimateLocalCleanup() throws {
        let retained = try fixture(keepingCloud: true, stoppingAt: .destinationSaved)
        let cleaner = try cleanup(retained)
        let receipt = try cleaner.enqueueCancellation(journal: retained.journal, cancelledControl: nil)
        try retained.store.cancel(retained.journal)
        let other = try fixture()
        _ = try cleanup(other).enqueue(journal: other.journal, recoveryManifest: nil)
        try other.store.finish(other.journal)
        let otherQueueName = "cleanup-\(other.journal.transactionID.uuidString.lowercased()).json"
        let transferred = retained.root.appendingPathComponent(other.transaction.lastPathComponent)
        try FileManager.default.moveItem(at: other.transaction, to: transferred)
        try FileManager.default.moveItem(at: other.root.appendingPathComponent(otherQueueName),
            to: retained.root.appendingPathComponent(otherQueueName))
        let before = try treeBytes(retained.transaction)
        for entry in try cleaner.pendingReceipts() {
            try cleaner.runLocal(transactionID: entry.transactionID)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: transferred.path))
        XCTAssertEqual(try cleaner.pendingReceipts(), [receipt])
        XCTAssertEqual(try treeBytes(retained.transaction), before)
    }

    func testRetainedImportQueueCapacityRefusesCancellationWithoutLosingPendingEvidenceOrEvictingCopies() throws {
        let f = try fixture(stoppingAt: .preparingDestination)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var retainedIDs = Set<UUID>()
        for _ in 0..<StorageTransferCleanup.maximumReceipts {
            var journal = try StorageTransferJournal(choice: f.journal.choice, source: f.journal.source,
                destination: f.journal.destination, cloudBinding: f.journal.cloudBinding,
                startedAt: Date(timeIntervalSince1970: 0))
            journal = try journal.advancing(to: .sourceSaved, sourceDigest: StorageTransferRecoverySchema.digest(userBytes))
            journal = try journal.advancing(to: .recoveryCopySaved).advancing(to: .preparingDestination)
            let receipt = try StorageTransferCleanupReceipt(cancelledJournal: journal, control: nil, ownedDirectories: [])
            let directory = f.root.appendingPathComponent(journal.transactionID.uuidString.lowercased())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try userBytes.write(to: directory.appendingPathComponent("payload-v1.json"))
            try encoder.encode(receipt).write(to: f.root.appendingPathComponent("cleanup-\(journal.transactionID.uuidString.lowercased()).json"))
            retainedIDs.insert(journal.transactionID)
        }
        let cleaner = try cleanup(f)
        let before = try treeBytes(f.root)
        XCTAssertThrowsError(try cleaner.enqueueCancellation(journal: f.journal, cancelledControl: nil)) {
            XCTAssertEqual($0 as? StorageTransferCleanupError, .limitExceeded)
        }
        let pending = try cleaner.pendingReceipts()
        XCTAssertEqual(Set(pending.map(\.transactionID)), retainedIDs)
        try cleaner.runLocal(transactionID: XCTUnwrap(pending.first).transactionID)
        XCTAssertEqual(try treeBytes(f.root), before)
        XCTAssertEqual(try f.store.load(), f.journal)
    }

    private func treeBytes(_ directory: URL) throws -> [String: Data] {
        let entries = try XCTUnwrap(FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]))
        var result: [String: Data] = [:]
        for case let url as URL in entries {
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                result[relative + "/"] = Data()
            } else { result[relative] = try Data(contentsOf: url) }
        }
        return result
    }

    func testPossibleUnacknowledgedUploadRequiresExactCancelledFenceBeforeLocalCancellation() async throws {
        let f = try fixture(replacesCloud: true, stoppingAt: .sourceSaved)
        let cleaner = try cleanup(f)
        XCTAssertThrowsError(try cleaner.enqueueCancellation(journal: f.journal, cancelledControl: nil))
        let manifest = try XCTUnwrap(f.manifest)
        let staging = try StorageTransferRecoveryControl(manifest: manifest)
        XCTAssertThrowsError(try cleaner.enqueueCancellation(journal: f.journal, cancelledControl: staging))
        let different = try StorageTransferRecoveryControl(manifest: StorageTransferRecoveryManifest(
            transactionID: f.journal.transactionID, accountFingerprint: account, payload: Data("different".utf8))).cancelling()
        XCTAssertThrowsError(try cleaner.enqueueCancellation(journal: f.journal, cancelledControl: different))
        let backend = CleanupRemoteFake(account: account)
        let recovery = StorageTransferRemoteRecovery(backend: backend, validateAccess: {})
        let cancelled = try await recovery.cancelUnclaimed(manifest: manifest)
        let queued = try cleaner.enqueueCancellation(journal: f.journal, cancelledControl: cancelled.envelope.control)
        XCTAssertEqual(queued.recoveryManifest, manifest)
        XCTAssertNil(queued.committedSelection)
        try f.store.cancel(f.journal)
        try cleaner.runLocal(transactionID: f.journal.transactionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.transaction.path))
        let late = try manifest.chunk(0, from: userBytes)
        backend.chunks[late.recordName] = late
        let result = try await cleaner.retryRemoteCleanup(expectedBinding: f.journal.cloudBinding,
            recovery: recovery, validateAccess: {})
        XCTAssertEqual(result.completed, 1)
        XCTAssertNil(backend.chunks[late.recordName])
        XCTAssertEqual(try cleaner.pendingReceipts().first?.recoveryManifest, manifest)
        XCTAssertNil(try f.store.committedSelection())
    }

    func testOnlyPreStagingRequestedCancellationMayOmitReplacementFence() throws {
        let requested = try fixture(replacesCloud: true, stoppingAt: .requested)
        let cleaner = try cleanup(requested)
        _ = try cleaner.enqueueCancellation(journal: requested.journal, cancelledControl: nil)
        try requested.store.cancel(requested.journal)
        try cleaner.runLocal(transactionID: requested.journal.transactionID)
        XCTAssertTrue(try cleaner.pendingReceipts().isEmpty)
        for phase in [StorageTransferJournal.Phase.preparingDestination, .destinationSaved, .sourceRetired] {
            let tooLate = try fixture(replacesCloud: true, stoppingAt: phase)
            let control = try StorageTransferRecoveryControl(manifest: XCTUnwrap(tooLate.manifest)).cancelling()
            XCTAssertThrowsError(try cleanup(tooLate).enqueueCancellation(journal: tooLate.journal, cancelledControl: control))
            XCTAssertEqual(try Data(contentsOf: tooLate.sourceStore), userBytes)
        }
    }

    func testFreshInstallRemoteCancellationNeverAuthorizesAHiddenLocalTransactionDirectory() async throws {
        let f = try fixture(replacesCloud: true, stoppingAt: .requested)
        let cleaner = try cleanup(f)
        let backend = CleanupRemoteFake(account: account)
        let recovery = StorageTransferRemoteRecovery(backend: backend, validateAccess: {})
        let manifest = try XCTUnwrap(f.manifest)
        let cancelled = try await recovery.cancelUnclaimed(manifest: manifest)
        XCTAssertThrowsError(try cleaner.enqueueRemoteCancellation(binding: f.journal.cloudBinding,
            cancelledControl: cancelled.envelope.control))
        try f.store.cancel(f.journal)
        XCTAssertThrowsError(try cleaner.enqueueRemoteCancellation(binding: f.journal.cloudBinding,
            cancelledControl: cancelled.envelope.control))
        XCTAssertEqual(try Data(contentsOf: f.sourceStore), userBytes)
        // Simulate a genuinely fresh installation with no transaction files.
        try FileManager.default.removeItem(at: f.transaction)
        let receipt = try cleaner.enqueueRemoteCancellation(binding: f.journal.cloudBinding,
            cancelledControl: cancelled.envelope.control)
        XCTAssertNil(receipt.source)
        XCTAssertNil(receipt.committedSelection)
        XCTAssertTrue(receipt.localRemoved)
        XCTAssertTrue(receipt.ownedDirectories.isEmpty)
        let result = try await cleaner.retryRemoteCleanup(expectedBinding: f.journal.cloudBinding,
            recovery: recovery, validateAccess: {})
        XCTAssertEqual(result.completed, 1)
        XCTAssertEqual(try cleaner.pendingReceipts().first?.recoveryManifest, manifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.transaction.path))
    }
}

@MainActor
private final class CleanupRemoteFake: StorageTransferRecoveryBackend {
    enum Failure: Error { case network }
    let account: String
    var verifications = 0
    var control: StorageTransferRecoveryEnvelope?
    var chunks: [String: StorageTransferRecoveryChunk] = [:]
    var receipts: [UUID: StorageTransferRecoveryControl] = [:]
    var failDeletes = false
    private var version = 0
    init(account: String) { self.account = account }
    func verifyAccount(_ fingerprint: String) async throws {
        verifications += 1
        guard account == fingerprint else { throw StorageTransferRecoveryError.identityMismatch }
    }
    func readControl() async throws -> StorageTransferRecoveryEnvelope? { control }
    func compareAndSwapControl(_ value: StorageTransferRecoveryControl,
                               replacing previous: StorageTransferRecoveryEnvelope?) async throws -> StorageTransferRecoveryEnvelope {
        guard control == previous else { throw StorageTransferRecoveryError.staleControl }
        version += 1
        let result = StorageTransferRecoveryEnvelope(control: value, changeTag: "synthetic-version-\(version)")
        control = result
        return result
    }
    func readChunk(manifest: StorageTransferRecoveryManifest, index: Int) async throws -> StorageTransferRecoveryChunk? {
        chunks["chunk-\(manifest.transactionID.uuidString.lowercased())-\(index)"]
    }
    func saveChunkIfAbsent(_ chunk: StorageTransferRecoveryChunk) async throws {
        if let prior = chunks[chunk.recordName], prior != chunk { throw StorageTransferRecoveryError.corruptChunk }
        chunks[chunk.recordName] = chunk
    }
    func retainTerminalReceipt(_ control: StorageTransferRecoveryControl) async throws {
        guard control.isTerminal else { throw StorageTransferRecoveryError.invalidControl }
        receipts[control.manifest.transactionID] = control
    }
    func readTerminalReceipt(transactionID: UUID) async throws -> StorageTransferRecoveryControl? { receipts[transactionID] }
    func deleteChunkIfMatches(_ chunk: StorageTransferRecoveryChunk,
                              terminalReceipt: StorageTransferRecoveryControl) async throws {
        if failDeletes { throw Failure.network }
        guard terminalReceipt.isTerminal, receipts[terminalReceipt.manifest.transactionID] == terminalReceipt,
              chunks[chunk.recordName] == chunk else { throw StorageTransferRecoveryError.staleControl }
        chunks.removeValue(forKey: chunk.recordName)
    }
}
