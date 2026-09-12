import Foundation
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferRemoteRecoveryTests: XCTestCase {
    private let account = String(repeating: "a", count: 64)
    private let otherAccount = String(repeating: "b", count: 64)
    private let payload = Data("frozen synthetic storage snapshot".utf8)

    private func manifest(_ bytes: Data? = nil, transactionID: UUID = UUID(), previousDatasetGenerationID: UUID? = nil) throws -> StorageTransferRecoveryManifest {
        try StorageTransferRecoveryManifest(transactionID: transactionID,
            accountFingerprint: account, payload: bytes ?? payload, chunkByteLimit: 8,
            previousDatasetGenerationID: previousDatasetGenerationID)
    }

    private func backend() -> RecoveryBackendFake { RecoveryBackendFake(accountFingerprint: account) }

    private func recovery(_ backend: RecoveryBackendFake) -> StorageTransferRemoteRecovery {
        StorageTransferRemoteRecovery(backend: backend, validateAccess: {})
    }

    private func expect(_ failure: StorageTransferRecoveryError,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected a fail-closed recovery error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? StorageTransferRecoveryError, failure, file: file, line: line)
        }
    }

    private func altered<T: Codable>(_ value: T, _ mutate: (inout [String: Any]) -> Void) throws -> T {
        let data = try JSONEncoder().encode(value)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        mutate(&object)
        return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testChunkAndWholePayloadDigestsAreValidatedAfterCodableRoundTrip() throws {
        let original = try manifest()
        let decoded = try JSONDecoder().decode(StorageTransferRecoveryManifest.self,
                                               from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        try decoded.validate(payload: payload)
        XCTAssertGreaterThan(decoded.chunks.count, 1)
        for part in decoded.chunks {
            try decoded.chunk(part.index, from: payload).validate(manifest: decoded, index: part.index)
        }
        var different = payload
        different[0] ^= 1
        XCTAssertThrowsError(try decoded.validate(payload: different))
        let wrongWholeHash = try altered(decoded) { $0["payloadSHA256"] = String(repeating: "c", count: 64) }
        XCTAssertThrowsError(try wrongWholeHash.validate(payload: payload))
    }

    func testManifestRejectsGapsDuplicateIndexesWrongSizesAndUnsupportedFormats() throws {
        let good = try manifest()
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["formatVersion"] = 2 },
            { $0["payloadFormat"] = "unknown" },
            { $0["accountFingerprint"] = "not-an-account-digest" },
            { $0["payloadSHA256"] = String(repeating: "A", count: 64) },
            { $0["payloadByteCount"] = 0 },
            { $0["payloadByteCount"] = Int.max },
            { $0["chunkByteLimit"] = StorageTransferRecoverySchema.maximumChunkBytes + 1 },
            { $0["chunks"] = [] },
            { value in
                var chunks = value["chunks"] as! [[String: Any]]
                chunks[1]["index"] = 0
                value["chunks"] = chunks
            },
            { value in
                var chunks = value["chunks"] as! [[String: Any]]
                chunks[0]["byteCount"] = 7
                value["chunks"] = chunks
            },
            { value in
                var chunks = value["chunks"] as! [[String: Any]]
                chunks.removeLast()
                value["chunks"] = chunks
            }
        ]
        for mutation in mutations { XCTAssertThrowsError(try altered(good, mutation).validate()) }
        XCTAssertThrowsError(try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account,
            payload: Data(), chunkByteLimit: 1))
        XCTAssertThrowsError(try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account,
            payload: Data(repeating: 1, count: 257), chunkByteLimit: 1))
        XCTAssertThrowsError(try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: account,
            payload: payload, chunkByteLimit: 0))
    }

    func testControlCannotSkipBackupAndReplacementAcknowledgmentsOrForgeCommittedDigest() throws {
        let start = try StorageTransferRecoveryControl(manifest: manifest())
        XCTAssertTrue(start.blocksWriters)
        XCTAssertThrowsError(try start.advancing(to: .replacing))
        let verified = try start.advancing(to: .backupVerified)
        XCTAssertTrue(verified.blocksWriters)
        let replacing = try verified.advancing(to: .replacing)
        XCTAssertThrowsError(try replacing.advancing(to: .committed))
        XCTAssertThrowsError(try replacing.advancing(to: .committed, verifiedDestinationSHA256: otherAccount))
        let committed = try replacing.advancing(to: .committed,
                                                verifiedDestinationSHA256: start.manifest.payloadSHA256)
        XCTAssertFalse(committed.blocksWriters)
        try JSONDecoder().decode(StorageTransferRecoveryControl.self,
                                 from: JSONEncoder().encode(committed)).validate()
        XCTAssertThrowsError(try altered(committed) { $0["revision"] = 0 }.validate())
        XCTAssertThrowsError(try verified.advancing(to: .replacing,
                                                   verifiedDestinationSHA256: start.manifest.payloadSHA256))
    }

    func testAcknowledgedChunksAndFullReadbackPrecedeReplacementAndCommit() async throws {
        let remote = backend()
        let coordinator = recovery(remote)
        let expected = try manifest()
        let staged = try await coordinator.stage(manifest: expected, payload: payload)
        XCTAssertEqual(staged.envelope.control.phase, .backupVerified)
        XCTAssertEqual(remote.chunkSaves, expected.chunks.count)
        XCTAssertGreaterThanOrEqual(remote.chunkReads, expected.chunks.count * 2)
        let permit = try await coordinator.authorizeReplacement(manifest: expected)
        XCTAssertEqual(permit.envelope.control.phase, .replacing)
        try await coordinator.revalidateReplacement(permit)
        let committed = try await coordinator.commitReplacement(manifest: expected,
            verifiedDestinationSHA256: expected.payloadSHA256)
        XCTAssertEqual(committed.envelope.control.phase, .committed)
        XCTAssertEqual(remote.receipts[expected.transactionID], committed.envelope.control)
        XCTAssertEqual(remote.chunks.count, expected.chunks.count)
        XCTAssertEqual(remote.savedPhases, [.staging, .backupVerified, .replacing, .committed])
    }

    func testMissingAcknowledgedChunkCannotProduceBackupOrDestructionReceipt() async throws {
        let remote = backend()
        remote.discardChunkWrites = true
        let expected = try manifest()
        await expect(.missingChunk) { _ = try await self.recovery(remote).stage(manifest: expected, payload: self.payload) }
        XCTAssertEqual(remote.control?.control.phase, .staging)
        await expect(.incompleteBackup) { _ = try await self.recovery(remote).authorizeReplacement(manifest: expected) }
        XCTAssertEqual(remote.savedPhases, [.staging])
    }

    func testInterruptedStagingResumesOriginalIdentityAndUploadsOnlyMissingChunks() async throws {
        let remote = backend()
        remote.failAfterChunkSaves = 1
        let expected = try manifest()
        do {
            _ = try await recovery(remote).stage(manifest: expected, payload: payload)
            XCTFail("Expected interrupted upload")
        } catch { XCTAssertEqual(error as? RecoveryBackendFake.Failure, .transport) }
        XCTAssertEqual(remote.control?.control.phase, .staging)
        XCTAssertEqual(remote.chunkSaves, 1)
        remote.failAfterChunkSaves = nil
        let reopened = recovery(remote)
        let result = try await reopened.stage(manifest: expected, payload: payload)
        XCTAssertEqual(result.envelope.control.manifest.transactionID, expected.transactionID)
        XCTAssertEqual(remote.chunkSaves, expected.chunks.count)
        XCTAssertEqual(remote.savedPhases, [.staging, .backupVerified])
        let restored = try await recovery(remote).recover(manifest: expected)
        XCTAssertEqual(restored.bytes, payload)
    }

    func testFreshInstallSeesPendingBeforeMountAndCannotSubstituteTransactionOrBytes() async throws {
        let remote = backend()
        let expected = try manifest()
        _ = try await recovery(remote).stage(manifest: expected, payload: payload)
        let fresh = recovery(remote)
        let pending = try await fresh.inspect(accountFingerprint: account)
        XCTAssertEqual(pending?.control.blocksWriters, true)
        let differentTransaction = try manifest()
        await expect(.conflictingTransaction) {
            _ = try await fresh.stage(manifest: differentTransaction, payload: self.payload)
        }
        let changedBytes = Data("a different frozen copy".utf8)
        let differentPayload = try manifest(changedBytes, transactionID: expected.transactionID)
        await expect(.conflictingTransaction) { _ = try await fresh.stage(manifest: differentPayload, payload: changedBytes) }
        await expect(.identityMismatch) { _ = try await fresh.recover(manifest: differentPayload) }
        XCTAssertEqual(remote.control?.control.manifest, expected)
    }

    func testCorruptedOrCrossTransactionChunkFailsRemoteRecovery() async throws {
        for corruption in 0..<3 {
            let remote = backend()
            let expected = try manifest()
            _ = try await recovery(remote).stage(manifest: expected, payload: payload)
            let original = try expected.chunk(0, from: payload)
            remote.chunks[original.recordName] = StorageTransferRecoveryChunk(
                transactionID: corruption == 1 ? UUID() : original.transactionID,
                accountFingerprint: corruption == 2 ? otherAccount : original.accountFingerprint,
                payloadSHA256: original.payloadSHA256, index: 0,
                bytes: corruption == 0 ? Data(repeating: 0, count: original.bytes.count) : original.bytes)
            await expect(corruption == 0 ? .corruptChunk : .identityMismatch) {
                _ = try await self.recovery(remote).authorizeReplacement(manifest: expected)
            }
            XCTAssertEqual(remote.control?.control.phase, .backupVerified)
        }
    }

    func testAccountChangeDuringReadCannotAuthorizeReplacementOnEitherAccount() async throws {
        let remote = backend()
        let expected = try manifest()
        _ = try await recovery(remote).stage(manifest: expected, payload: payload)
        remote.onChunkRead = { remote.accountFingerprint = self.otherAccount }
        await expect(.identityMismatch) { _ = try await self.recovery(remote).authorizeReplacement(manifest: expected) }
        XCTAssertEqual(remote.control?.control.phase, .backupVerified)
    }

    func testSceneOrJournalInvalidationAfterAwaitStopsBeforeNextMutation() async throws {
        let remote = backend()
        let expected = try manifest()
        _ = try await recovery(remote).stage(manifest: expected, payload: payload)
        var accessIsValid = true
        let guarded = StorageTransferRemoteRecovery(backend: remote, validateAccess: {
            guard accessIsValid else { throw StorageTransferRecoveryError.staleControl }
        })
        remote.onChunkRead = { accessIsValid = false }
        await expect(.staleControl) { _ = try await guarded.authorizeReplacement(manifest: expected) }
        XCTAssertEqual(remote.control?.control.phase, .backupVerified)
    }

    func testServerCASConflictCannotOverwriteACompetingPendingTransaction() async throws {
        let remote = backend()
        let expected = try manifest()
        let competing = try StorageTransferRecoveryControl(manifest: manifest())
        remote.beforeCAS = {
            remote.control = StorageTransferRecoveryEnvelope(control: competing, changeTag: "competing-server-tag")
        }
        await expect(.staleControl) { _ = try await self.recovery(remote).stage(manifest: expected, payload: self.payload) }
        XCTAssertEqual(remote.control?.control, competing)
        XCTAssertTrue(remote.chunks.isEmpty)
    }

    func testLostReplacementAcknowledgmentRetriesSameServerTransactionWithoutRepeatingPhase() async throws {
        let remote = backend()
        let expected = try manifest()
        _ = try await recovery(remote).stage(manifest: expected, payload: payload)
        remote.loseAcknowledgmentAt = .replacing
        do {
            _ = try await recovery(remote).authorizeReplacement(manifest: expected)
            XCTFail("Expected uncertain network response")
        } catch { XCTAssertEqual(error as? RecoveryBackendFake.Failure, .transport) }
        XCTAssertEqual(remote.control?.control.phase, .replacing)
        let retry = try await recovery(remote).authorizeReplacement(manifest: expected)
        XCTAssertEqual(retry.envelope, remote.control)
        XCTAssertEqual(remote.savedPhases.filter { $0 == .replacing }.count, 1)
    }

    func testWrongDestinationProofAndStaleDestructionPermitAreRejected() async throws {
        let remote = backend()
        let expected = try manifest()
        _ = try await recovery(remote).stage(manifest: expected, payload: payload)
        let permit = try await recovery(remote).authorizeReplacement(manifest: expected)
        await expect(.destinationMismatch) {
            _ = try await self.recovery(remote).commitReplacement(manifest: expected,
                verifiedDestinationSHA256: self.otherAccount)
        }
        XCTAssertEqual(remote.control?.control.phase, .replacing)
        _ = try await recovery(remote).commitReplacement(manifest: expected, verifiedDestinationSHA256: expected.payloadSHA256)
        await expect(.staleControl) { try await self.recovery(remote).revalidateReplacement(permit) }
    }

    func testCancellationRetainsPreviousDatasetGenerationAndRejectsStaleLineage() async throws {
        let remote = backend()
        let coordinator = recovery(remote)
        let first = try manifest()
        _ = try await coordinator.stage(manifest: first, payload: payload)
        _ = try await coordinator.authorizeReplacement(manifest: first)
        _ = try await coordinator.commitReplacement(manifest: first, verifiedDestinationSHA256: first.payloadSHA256)
        let stale = try manifest()
        await expect(.conflictingTransaction) {
            _ = try await coordinator.stage(manifest: stale, payload: self.payload,
                replacingTerminalTransactionID: first.transactionID)
        }
        XCTAssertEqual(remote.control?.control.datasetGenerationID, first.transactionID)
        let next = try manifest(previousDatasetGenerationID: first.transactionID)
        _ = try await coordinator.stage(manifest: next, payload: payload,
            replacingTerminalTransactionID: first.transactionID)
        XCTAssertEqual(remote.control?.control.datasetGenerationID, first.transactionID)
        let cancelled = try await coordinator.cancelBeforeReplacement(manifest: next)
        XCTAssertEqual(cancelled.envelope.control.datasetGenerationID, first.transactionID)
        let third = try manifest(previousDatasetGenerationID: first.transactionID)
        _ = try await coordinator.stage(manifest: third, payload: payload,
            replacingTerminalTransactionID: next.transactionID)
        XCTAssertEqual(remote.control?.control.datasetGenerationID, first.transactionID)
    }

    func testAbsentControlCannotInventPreviousDatasetGeneration() async throws {
        let remote = backend()
        let next = try manifest(previousDatasetGenerationID: UUID())
        await expect(.staleControl) { _ = try await self.recovery(remote).stage(manifest: next, payload: self.payload) }
        XCTAssertNil(remote.control)
        XCTAssertTrue(remote.chunks.isEmpty)
    }

    func testNextTransactionRequiresExplicitCommittedPredecessorAndRetainedReceipt() async throws {
        let remote = backend()
        let first = try manifest()
        let coordinator = recovery(remote)
        _ = try await coordinator.stage(manifest: first, payload: payload)
        _ = try await coordinator.authorizeReplacement(manifest: first)
        _ = try await coordinator.commitReplacement(manifest: first, verifiedDestinationSHA256: first.payloadSHA256)
        let next = try manifest(previousDatasetGenerationID: first.transactionID)
        await expect(.conflictingTransaction) { _ = try await coordinator.stage(manifest: next, payload: self.payload) }
        remote.receipts.removeAll()
        remote.discardReceiptWrites = true
        await expect(.staleControl) {
            _ = try await coordinator.stage(manifest: next, payload: self.payload,
                                            replacingTerminalTransactionID: first.transactionID)
        }
        XCTAssertEqual(remote.control?.control.manifest.transactionID, first.transactionID)
        remote.discardReceiptWrites = false
        _ = try await coordinator.stage(manifest: next, payload: payload,
                                        replacingTerminalTransactionID: first.transactionID)
        XCTAssertEqual(remote.control?.control.manifest.transactionID, next.transactionID)
        XCTAssertEqual(remote.receipts[first.transactionID]?.phase, .committed)
        XCTAssertEqual(remote.chunks.count, first.chunks.count + next.chunks.count)
    }

    func testMissingPartialBackupCanBeExplicitlyCancelledAfterUninstallWithoutResurrection() async throws {
        let remote = backend()
        let original = try manifest()
        remote.failAfterChunkSaves = 1
        do {
            _ = try await recovery(remote).stage(manifest: original, payload: payload)
            XCTFail("Expected interrupted upload")
        } catch { XCTAssertEqual(error as? RecoveryBackendFake.Failure, .transport) }
        let installedAgain = recovery(remote)
        let cancelled = try await installedAgain.cancelBeforeReplacement(manifest: original)
        XCTAssertEqual(cancelled.envelope.control.phase, .cancelled)
        XCTAssertEqual(cancelled.envelope.control.cancelledFrom, .staging)
        XCTAssertFalse(cancelled.envelope.control.blocksWriters)
        XCTAssertNil(cancelled.envelope.control.verifiedDestinationSHA256)
        XCTAssertEqual(remote.chunkDeletes, 0)
        XCTAssertEqual(remote.receipts[original.transactionID], cancelled.envelope.control)
        await expect(.staleControl) { _ = try await installedAgain.stage(manifest: original, payload: self.payload) }
        await expect(.incompleteBackup) { _ = try await installedAgain.authorizeReplacement(manifest: original) }
        let repeated = try await installedAgain.cancelBeforeReplacement(manifest: original)
        XCTAssertEqual(repeated, cancelled)
        XCTAssertEqual(remote.savedPhases, [.staging, .cancelled])
    }

    func testCancellationCannotCrossReplacementBoundaryOrClaimACommittedDestination() async throws {
        let remote = backend()
        let original = try manifest()
        _ = try await recovery(remote).stage(manifest: original, payload: payload)
        let ready = try XCTUnwrap(remote.control?.control)
        let cancelled = try ready.cancelling()
        XCTAssertEqual(cancelled.cancelledFrom, .backupVerified)
        try cancelled.validate()
        XCTAssertThrowsError(try cancelled.advancing(to: .committed,
                                                     verifiedDestinationSHA256: original.payloadSHA256))
        XCTAssertThrowsError(try altered(cancelled) { $0["cancelledFrom"] = 2 }.validate())
        XCTAssertThrowsError(try altered(cancelled) { $0["verifiedDestinationSHA256"] = original.payloadSHA256 }.validate())
        _ = try await recovery(remote).authorizeReplacement(manifest: original)
        await expect(.staleControl) { _ = try await self.recovery(remote).cancelBeforeReplacement(manifest: original) }
        _ = try await recovery(remote).commitReplacement(manifest: original,
                                                        verifiedDestinationSHA256: original.payloadSHA256)
        await expect(.staleControl) { _ = try await self.recovery(remote).cancelBeforeReplacement(manifest: original) }
        XCTAssertEqual(remote.savedPhases, [.staging, .backupVerified, .replacing, .committed])
    }

    func testCancellationLosesServerCASToReplacementWithoutClearingNewState() async throws {
        let remote = backend()
        let original = try manifest()
        _ = try await recovery(remote).stage(manifest: original, payload: payload)
        let replacement = try XCTUnwrap(remote.control?.control).advancing(to: .replacing)
        remote.beforeCAS = {
            remote.control = StorageTransferRecoveryEnvelope(control: replacement, changeTag: "replacement-won")
        }
        await expect(.staleControl) { _ = try await self.recovery(remote).cancelBeforeReplacement(manifest: original) }
        XCTAssertEqual(remote.control?.control.phase, .replacing)
        XCTAssertTrue(remote.receipts.isEmpty)
        XCTAssertEqual(remote.chunkDeletes, 0)
    }

    func testCancelledPredecessorAndItsChunksStayDistinctFromNewTransaction() async throws {
        let remote = backend()
        let first = try manifest()
        _ = try await recovery(remote).stage(manifest: first, payload: payload)
        _ = try await recovery(remote).cancelBeforeReplacement(manifest: first)
        let next = try manifest()
        _ = try await recovery(remote).stage(manifest: next, payload: payload,
                                            replacingTerminalTransactionID: first.transactionID)
        let current = remote.control
        try await recovery(remote).cleanupPayload(manifest: first)
        XCTAssertEqual(remote.control, current)
        XCTAssertEqual(remote.chunks.count, next.chunks.count)
        for chunk in remote.chunks.values { XCTAssertEqual(chunk.transactionID, next.transactionID) }
        XCTAssertEqual(remote.receipts[first.transactionID]?.phase, .cancelled)
        await expect(.staleControl) { try await self.recovery(remote).cleanupPayload(manifest: next) }
        _ = try await recovery(remote).cancelBeforeReplacement(manifest: next)
        await expect(.conflictingTransaction) {
            _ = try await self.recovery(remote).stage(manifest: first, payload: self.payload,
                                                       replacingTerminalTransactionID: next.transactionID)
        }
    }

    func testTerminalCleanupRequiresReadbackAndRetryAfterLostDeleteAcknowledgment() async throws {
        let remote = backend()
        let original = try manifest()
        _ = try await recovery(remote).stage(manifest: original, payload: payload)
        _ = try await recovery(remote).cancelBeforeReplacement(manifest: original)
        remote.loseDeleteAcknowledgment = true
        do {
            try await recovery(remote).cleanupPayload(manifest: original)
            XCTFail("Expected uncertain delete response")
        } catch { XCTAssertEqual(error as? RecoveryBackendFake.Failure, .transport) }
        XCTAssertEqual(remote.chunks.count, original.chunks.count - 1)
        try await recovery(remote).cleanupPayload(manifest: original)
        XCTAssertTrue(remote.chunks.isEmpty)
        XCTAssertEqual(remote.receipts[original.transactionID]?.phase, .cancelled)
        XCTAssertEqual(remote.control?.control.phase, .cancelled)
        // A submitted pre-cancellation save can arrive late. The retained
        // receipt still permits exact cleanup without unlocking a new upload.
        let late = try original.chunk(0, from: payload)
        remote.chunks[late.recordName] = late
        try await recovery(remote).cleanupPayload(manifest: original)
        XCTAssertTrue(remote.chunks.isEmpty)
    }

    func testCleanupRejectsUnacknowledgedOrConflictingChunkDeletion() async throws {
        for wrongIdentity in [false, true] {
            let remote = backend()
            let original = try manifest()
            _ = try await recovery(remote).stage(manifest: original, payload: payload)
            _ = try await recovery(remote).cancelBeforeReplacement(manifest: original)
            remote.discardChunkDeletes = true
            if wrongIdentity {
                let part = try original.chunk(0, from: payload)
                remote.chunks[part.recordName] = StorageTransferRecoveryChunk(transactionID: UUID(),
                    accountFingerprint: part.accountFingerprint, payloadSHA256: part.payloadSHA256,
                    index: part.index, bytes: part.bytes)
            }
            await expect(wrongIdentity ? .identityMismatch : .incompleteBackup) {
                try await self.recovery(remote).cleanupPayload(manifest: original)
            }
            XCTAssertEqual(remote.chunks.count, original.chunks.count)
            XCTAssertNotNil(remote.receipts[original.transactionID])
        }
    }

    func testCommittedRetrySucceedsAfterAcknowledgedPayloadCleanup() async throws {
        let remote = backend()
        let original = try manifest()
        let coordinator = recovery(remote)
        _ = try await coordinator.stage(manifest: original, payload: payload)
        _ = try await coordinator.authorizeReplacement(manifest: original)
        let committed = try await coordinator.commitReplacement(manifest: original,
            verifiedDestinationSHA256: original.payloadSHA256)
        try await coordinator.cleanupPayload(manifest: original)
        XCTAssertTrue(remote.chunks.isEmpty)
        let retry = try await coordinator.commitReplacement(manifest: original,
            verifiedDestinationSHA256: original.payloadSHA256)
        XCTAssertEqual(retry, committed)
        XCTAssertEqual(remote.savedPhases.filter { $0 == .committed }.count, 1)
    }

    func testUnclaimedCancellationCreatesDurableFenceWithoutUploadingAnyPayload() async throws {
        let remote = backend()
        let original = try manifest()
        let cancelled = try await recovery(remote).cancelUnclaimed(manifest: original)
        XCTAssertEqual(cancelled.envelope.control.phase, .cancelled)
        XCTAssertEqual(cancelled.envelope.control.cancelledFrom, .staging)
        XCTAssertEqual(remote.receipts[original.transactionID], cancelled.envelope.control)
        XCTAssertEqual(remote.chunkSaves, 0)
        XCTAssertEqual(remote.chunkReads, 0)
        XCTAssertEqual(remote.chunkDeletes, 0)
        let late = try StorageTransferRecoveryControl(manifest: original)
        await expect(.staleControl) { _ = try await remote.compareAndSwapControl(late, replacing: nil) }
        await expect(.staleControl) { _ = try await self.recovery(remote).stage(manifest: original, payload: self.payload) }
        let repeated = try await recovery(remote).cancelUnclaimed(manifest: original)
        XCTAssertEqual(repeated, cancelled)
        XCTAssertEqual(remote.savedPhases, [.cancelled])
    }

    func testUnclaimedCancellationRetainsNamedPredecessorAndPreservesItsDatasetGeneration() async throws {
        let remote = backend()
        let original = try manifest()
        let coordinator = recovery(remote)
        _ = try await coordinator.stage(manifest: original, payload: payload)
        _ = try await coordinator.authorizeReplacement(manifest: original)
        let first = try await coordinator.commitReplacement(manifest: original,
            verifiedDestinationSHA256: original.payloadSHA256)
        let oldEnvelope = remote.control
        let next = try manifest(previousDatasetGenerationID: original.transactionID)
        let saves = remote.chunkSaves
        let cancelled = try await coordinator.cancelUnclaimed(manifest: next,
            replacingTerminalTransactionID: original.transactionID)
        XCTAssertEqual(cancelled.envelope.control.datasetGenerationID, original.transactionID)
        XCTAssertEqual(remote.receipts[original.transactionID], first.envelope.control)
        XCTAssertEqual(remote.receipts[next.transactionID], cancelled.envelope.control)
        XCTAssertEqual(remote.chunkSaves, saves)
        let delayed = try StorageTransferRecoveryControl(manifest: next)
        await expect(.staleControl) { _ = try await remote.compareAndSwapControl(delayed, replacing: oldEnvelope) }
    }

    func testUnclaimedCancellationRejectsWrongBaselineLineageAndOtherPendingTransaction() async throws {
        let remote = backend()
        let coordinator = recovery(remote)
        let original = try manifest()
        await expect(.staleControl) {
            _ = try await coordinator.cancelUnclaimed(manifest: original, replacingTerminalTransactionID: UUID())
        }
        let wrongLineage = try manifest(previousDatasetGenerationID: UUID())
        await expect(.staleControl) { _ = try await coordinator.cancelUnclaimed(manifest: wrongLineage) }
        _ = try await coordinator.stage(manifest: original, payload: payload)
        let competing = try manifest()
        await expect(.conflictingTransaction) {
            _ = try await coordinator.cancelUnclaimed(manifest: competing, replacingTerminalTransactionID: original.transactionID)
        }
        _ = try await coordinator.cancelBeforeReplacement(manifest: original)
        await expect(.conflictingTransaction) { _ = try await coordinator.cancelUnclaimed(manifest: competing) }
        await expect(.conflictingTransaction) {
            _ = try await coordinator.cancelUnclaimed(manifest: wrongLineage, replacingTerminalTransactionID: original.transactionID)
        }
        XCTAssertEqual(remote.control?.control.manifest, original)
        XCTAssertEqual(remote.chunkDeletes, 0)
    }

    func testUnclaimedCancellationDelegatesOwnUploadButNeverOwnReplacement() async throws {
        let remote = backend()
        let original = try manifest()
        _ = try await recovery(remote).stage(manifest: original, payload: payload)
        let saved = remote.chunkSaves
        let cancelled = try await recovery(remote).cancelUnclaimed(manifest: original)
        XCTAssertEqual(cancelled.envelope.control.cancelledFrom, .backupVerified)
        XCTAssertEqual(remote.chunkSaves, saved)
        let other = backend()
        _ = try await recovery(other).stage(manifest: original, payload: payload)
        _ = try await recovery(other).authorizeReplacement(manifest: original)
        await expect(.staleControl) { _ = try await self.recovery(other).cancelUnclaimed(manifest: original) }
        XCTAssertEqual(other.control?.control.phase, .replacing)
    }

    func testUnclaimedCancellationCASRaceStopsWithoutDeletingOrDisplacingConcurrentState() async throws {
        let remote = backend()
        let original = try manifest()
        let competing = try StorageTransferRecoveryControl(manifest: manifest())
        remote.beforeCAS = {
            remote.control = StorageTransferRecoveryEnvelope(control: competing, changeTag: "concurrent-create")
        }
        await expect(.staleControl) { _ = try await self.recovery(remote).cancelUnclaimed(manifest: original) }
        XCTAssertEqual(remote.control?.control, competing)
        XCTAssertTrue(remote.receipts.isEmpty)
        XCTAssertEqual(remote.chunkSaves, 0)
    }

    func testUnclaimedCancellationRequiresReceiptAcknowledgmentAndRetriesSameFence() async throws {
        let remote = backend()
        let original = try manifest()
        remote.discardReceiptWrites = true
        await expect(.staleControl) { _ = try await self.recovery(remote).cancelUnclaimed(manifest: original) }
        XCTAssertEqual(remote.control?.control.phase, .cancelled)
        remote.discardReceiptWrites = false
        let acknowledged = try await recovery(remote).cancelUnclaimed(manifest: original)
        XCTAssertEqual(remote.receipts[original.transactionID], acknowledged.envelope.control)
        XCTAssertEqual(remote.savedPhases, [.cancelled])
        XCTAssertEqual(remote.chunkSaves, 0)
    }

    func testArchivedCancellationIsReadOnlyAfterNewerTransactionCommits() async throws {
        let remote = backend()
        let coordinator = recovery(remote)
        let original = try manifest()
        let cancelled = try await coordinator.cancelUnclaimed(manifest: original)
        let next = try manifest()
        _ = try await coordinator.stage(manifest: next, payload: payload,
                                         replacingTerminalTransactionID: original.transactionID)
        _ = try await coordinator.authorizeReplacement(manifest: next)
        _ = try await coordinator.commitReplacement(manifest: next, verifiedDestinationSHA256: next.payloadSHA256)
        let current = remote.control
        let counts = [remote.controlReads, remote.chunkReads, remote.chunkSaves, remote.chunkDeletes]
        let phases = remote.savedPhases
        let receipts = remote.receipts
        let archived = try await coordinator.archivedCancelledControl(manifest: original)
        XCTAssertEqual(archived, cancelled.envelope.control)
        XCTAssertEqual(remote.control, current)
        XCTAssertEqual(remote.savedPhases, phases)
        XCTAssertEqual(remote.receipts, receipts)
        XCTAssertEqual([remote.controlReads, remote.chunkReads, remote.chunkSaves, remote.chunkDeletes], counts)
    }

    func testArchivedCancellationRequiresAcknowledgedReceiptEvenIfCurrentControlIsCancelled() async throws {
        let remote = backend()
        let original = try manifest()
        remote.control = StorageTransferRecoveryEnvelope(
            control: try StorageTransferRecoveryControl(manifest: original).cancelling(), changeTag: "current-only")
        let absent = try await recovery(remote).archivedCancelledControl(manifest: original)
        XCTAssertNil(absent)
        XCTAssertTrue(remote.receipts.isEmpty)
        XCTAssertTrue(remote.savedPhases.isEmpty)
    }

    func testArchivedCancellationRejectsDifferentPayloadOrTransactionInReceipt() async throws {
        let remote = backend()
        let original = try manifest()
        _ = try await recovery(remote).cancelUnclaimed(manifest: original)
        let differentPayload = try manifest(Data("different frozen payload".utf8), transactionID: original.transactionID)
        await expect(.identityMismatch) {
            _ = try await self.recovery(remote).archivedCancelledControl(manifest: differentPayload)
        }
        remote.receipts[original.transactionID] = try StorageTransferRecoveryControl(manifest: manifest()).cancelling()
        await expect(.identityMismatch) { _ = try await self.recovery(remote).archivedCancelledControl(manifest: original) }
    }

    func testArchivedCancellationRejectsAccountMismatchAndAccountChangeDuringReadback() async throws {
        let remote = backend()
        let original = try manifest()
        let acknowledged = try await recovery(remote).cancelUnclaimed(manifest: original)
        let foreignManifest = try StorageTransferRecoveryManifest(transactionID: original.transactionID,
            accountFingerprint: otherAccount, payload: payload, chunkByteLimit: 8)
        remote.receipts[original.transactionID] = try StorageTransferRecoveryControl(manifest: foreignManifest).cancelling()
        await expect(.identityMismatch) { _ = try await self.recovery(remote).archivedCancelledControl(manifest: original) }
        remote.receipts[original.transactionID] = acknowledged.envelope.control
        remote.accountFingerprint = otherAccount
        await expect(.identityMismatch) { _ = try await self.recovery(remote).archivedCancelledControl(manifest: original) }
        remote.accountFingerprint = account
        remote.onReceiptRead = { remote.accountFingerprint = self.otherAccount }
        await expect(.identityMismatch) { _ = try await self.recovery(remote).archivedCancelledControl(manifest: original) }
    }

    func testArchivedCancellationRejectsCommittedPendingAndMalformedReceipts() async throws {
        let remote = backend()
        let original = try manifest()
        let initial = try StorageTransferRecoveryControl(manifest: original)
        let committed = try initial.advancing(to: .backupVerified).advancing(to: .replacing)
            .advancing(to: .committed, verifiedDestinationSHA256: original.payloadSHA256)
        for wrongPhase in [initial, committed] {
            remote.receipts[original.transactionID] = wrongPhase
            await expect(.staleControl) { _ = try await self.recovery(remote).archivedCancelledControl(manifest: original) }
        }
        remote.receipts[original.transactionID] = try altered(initial.cancelling()) { $0["revision"] = 9 }
        await expect(.invalidControl) { _ = try await self.recovery(remote).archivedCancelledControl(manifest: original) }
    }

    func testAdditionalValidationPreservesOriginalLeaseAndChecksAfterSuspension() async throws {
        let remote = backend()
        let original = try manifest()
        var originalLeaseValid = false
        var journalValid = true
        let protected = StorageTransferRemoteRecovery(backend: remote) {
            if !originalLeaseValid { throw StorageTransferRecoveryError.identityMismatch }
        }.withAdditionalValidation {
            if !journalValid { throw StorageTransferRecoveryError.staleControl }
        }
        await expect(.identityMismatch) { _ = try await protected.cancelUnclaimed(manifest: original) }
        XCTAssertEqual(remote.controlReads, 0)
        originalLeaseValid = true
        remote.onReceiptRead = { journalValid = false }
        await expect(.staleControl) { _ = try await protected.cancelUnclaimed(manifest: original) }
        XCTAssertNil(remote.control)
        XCTAssertTrue(remote.savedPhases.isEmpty)
        XCTAssertTrue(remote.receipts.isEmpty)
    }

    func testEnvelopeEqualityUsesStableServerRevisionAndControlNotArchiveBytes() throws {
        let control = try StorageTransferRecoveryControl(manifest: manifest())
        let saved = StorageTransferRecoveryEnvelope(control: control, changeTag: "same-server-revision", systemFieldsProof: "save-archive")
        let fetched = StorageTransferRecoveryEnvelope(control: control, changeTag: "same-server-revision", systemFieldsProof: "fetch-archive")
        try saved.validate()
        try fetched.validate()
        XCTAssertEqual(saved, fetched)
        XCTAssertNotEqual(saved, StorageTransferRecoveryEnvelope(control: control, changeTag: "new-server-revision", systemFieldsProof: "save-archive"))
        XCTAssertNotEqual(saved, StorageTransferRecoveryEnvelope(control: try control.cancelling(), changeTag: saved.changeTag,
            systemFieldsProof: saved.systemFieldsProof))
        XCTAssertThrowsError(try StorageTransferRecoveryEnvelope(control: control, changeTag: "revision", systemFieldsProof: "").validate())
        XCTAssertThrowsError(try StorageTransferRecoveryEnvelope(control: control, changeTag: "revision",
            systemFieldsProof: String(repeating: "x", count: 4_097)).validate())
    }
}

@MainActor
private final class RecoveryBackendFake: StorageTransferRecoveryBackend {
    enum Failure: Error, Equatable { case transport }
    var accountFingerprint: String
    var control: StorageTransferRecoveryEnvelope?
    var controlReads = 0
    var chunks: [String: StorageTransferRecoveryChunk] = [:]
    var receipts: [UUID: StorageTransferRecoveryControl] = [:]
    var savedPhases: [StorageTransferRecoveryControl.Phase] = []
    var chunkSaves = 0
    var chunkReads = 0
    var discardChunkWrites = false
    var discardReceiptWrites = false
    var discardChunkDeletes = false
    var loseDeleteAcknowledgment = false
    var chunkDeletes = 0
    var failAfterChunkSaves: Int?
    var loseAcknowledgmentAt: StorageTransferRecoveryControl.Phase?
    var onChunkRead: (() -> Void)?
    var onReceiptRead: (() -> Void)?
    var beforeCAS: (() -> Void)?
    private var version = 0

    init(accountFingerprint: String) { self.accountFingerprint = accountFingerprint }

    func verifyAccount(_ fingerprint: String) async throws {
        guard fingerprint == accountFingerprint else { throw StorageTransferRecoveryError.identityMismatch }
    }

    func readControl() async throws -> StorageTransferRecoveryEnvelope? {
        controlReads += 1
        return control
    }

    func compareAndSwapControl(_ next: StorageTransferRecoveryControl,
                               replacing previous: StorageTransferRecoveryEnvelope?) async throws -> StorageTransferRecoveryEnvelope {
        let callback = beforeCAS
        beforeCAS = nil
        callback?()
        guard control == previous else { throw StorageTransferRecoveryError.staleControl }
        try next.validate()
        version += 1
        let result = StorageTransferRecoveryEnvelope(control: next, changeTag: "server-version-\(version)")
        control = result
        savedPhases.append(next.phase)
        if loseAcknowledgmentAt == next.phase {
            loseAcknowledgmentAt = nil
            throw Failure.transport
        }
        return result
    }

    func readChunk(manifest: StorageTransferRecoveryManifest, index: Int) async throws -> StorageTransferRecoveryChunk? {
        chunkReads += 1
        let callback = onChunkRead
        onChunkRead = nil
        callback?()
        return chunks["chunk-\(manifest.transactionID.uuidString.lowercased())-\(index)"]
    }

    func saveChunkIfAbsent(_ chunk: StorageTransferRecoveryChunk) async throws {
        if let limit = failAfterChunkSaves, chunkSaves >= limit { throw Failure.transport }
        if let prior = chunks[chunk.recordName] {
            guard prior == chunk else { throw StorageTransferRecoveryError.corruptChunk }
            return
        }
        chunkSaves += 1
        if !discardChunkWrites { chunks[chunk.recordName] = chunk }
    }

    func retainTerminalReceipt(_ control: StorageTransferRecoveryControl) async throws {
        try control.validate()
        guard control.isTerminal else { throw StorageTransferRecoveryError.invalidControl }
        if let prior = receipts[control.manifest.transactionID], prior != control {
            throw StorageTransferRecoveryError.staleControl
        }
        if !discardReceiptWrites { receipts[control.manifest.transactionID] = control }
    }

    func readTerminalReceipt(transactionID: UUID) async throws -> StorageTransferRecoveryControl? {
        let callback = onReceiptRead
        onReceiptRead = nil
        callback?()
        return receipts[transactionID]
    }

    func deleteChunkIfMatches(_ chunk: StorageTransferRecoveryChunk,
                              terminalReceipt: StorageTransferRecoveryControl) async throws {
        try terminalReceipt.validate()
        guard terminalReceipt.isTerminal,
              receipts[terminalReceipt.manifest.transactionID] == terminalReceipt,
              chunks[chunk.recordName] == chunk else { throw StorageTransferRecoveryError.staleControl }
        try chunk.validate(manifest: terminalReceipt.manifest, index: chunk.index)
        chunkDeletes += 1
        if !discardChunkDeletes { chunks.removeValue(forKey: chunk.recordName) }
        if loseDeleteAcknowledgment {
            loseDeleteAcknowledgment = false
            throw Failure.transport
        }
    }
}
