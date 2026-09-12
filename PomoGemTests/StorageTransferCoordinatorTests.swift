import Foundation
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferCoordinatorTests: XCTestCase {
    private enum Interrupted: Error { case once }

    @MainActor private final class Effects {
        var failedEffect: String?
        var didFail = false
        var calls: [String] = []
        var sourceExists = true
        var targetVerified = false
        var backupAcknowledged = false
        var destinationPrepared = false
        let payload = Data("synthetic selected source".utf8)
        var digest: String { StorageTransferRecoverySchema.digest(payload) }
        let store: StorageTransferJournalStore

        init(store: StorageTransferJournalStore) { self.store = store }

        func entered(_ name: String) throws {
            calls.append(name)
            if name == failedEffect, !didFail {
                didFail = true
                throw Interrupted.once
            }
        }

        var live: StorageTransferEffects {
            StorageTransferEffects(captureSource: { [self] _ in
                try entered("capture")
                guard sourceExists else { throw StorageTransferError.invalidJournal }
                return digest
            }, saveRemoteRecovery: { [self] journal in
                try entered("backup")
                backupAcknowledged = true
                return try StorageTransferRecoveryManifest(transactionID: journal.transactionID,
                    accountFingerprint: journal.cloudBinding.accountFingerprint, payload: payload)
            }, prepareDestination: { [self] journal in
                try entered("prepare")
                guard sourceExists, try store.load()?.phase == .preparingDestination,
                      !journal.choice.replacesCloud || backupAcknowledged else {
                    throw StorageTransferError.recoveryCopyRequired
                }
                destinationPrepared = true
                return digest
            }, verifyDestination: { [self] _ in
                try entered("verify")
                guard destinationPrepared else { throw StorageTransferError.snapshotMismatch }
                targetVerified = true
                return digest
            }, promoteDestination: { [self] _ in
                try entered("promote")
                guard sourceExists, targetVerified else { throw StorageTransferError.snapshotMismatch }
            }, retireSource: { [self] journal in
                try entered("retire")
                guard targetVerified, try store.committedSelection()?.selection == journal.destination else {
                    throw StorageTransferError.invalidJournal
                }
                sourceExists = false
            }, enqueueCleanup: { [self] journal in
                try entered("cleanupQueue")
                guard !sourceExists, try store.load()?.phase == .sourceRetired,
                      try store.committedSelection()?.selection == journal.destination else { throw StorageTransferError.invalidJournal }
            })
        }
    }

    private func setup(_ choice: StorageTransferChoice) throws -> (StorageTransferJournalStore, StorageTransferJournal, Effects) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StorageTransferCoordinator-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = StorageTransferJournalStore(directory: directory)
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
            accountFingerprint: String(repeating: "a", count: 64)))
        let cloud = PersistenceDeploymentSelection.cloud(binding: binding)
        let local = PersistenceDeploymentSelection.localOnly(namespace: AccountDataNamespace())
        let journal = try StorageTransferJournal(choice: choice,
            source: choice == .disableCloudKeepingCopy ? cloud : local,
            destination: choice == .disableCloudKeepingCopy ? local : cloud, cloudBinding: binding)
        try store.begin(journal)
        return (store, journal, Effects(store: store))
    }

    func testCleanupQueueMustBeAcknowledgedBeforeTheLastJournalIsRemoved() async throws {
        let (store, journal, effects) = try setup(.enableCloudReplacingCloud)
        effects.failedEffect = "cleanupQueue"
        do {
            try await StorageTransferCoordinator(store: store, effects: effects.live)
                .resume(transactionID: journal.transactionID, validateTransfer: {})
            XCTFail("Expected interrupted durable queue write")
        } catch is Interrupted {}
        XCTAssertEqual(try store.load()?.phase, .sourceRetired)
        XCTAssertFalse(effects.sourceExists)
        try await StorageTransferCoordinator(store: store, effects: effects.live)
            .resume(transactionID: journal.transactionID, validateTransfer: {})
        XCTAssertNil(try store.load())
        XCTAssertEqual(effects.calls.filter { $0 == "retire" }.count, 1)
        XCTAssertEqual(effects.calls.filter { $0 == "cleanupQueue" }.count, 2)
    }

    func testFailureAtEveryEffectKeepsSourceAndResumesWithoutRepeatingAcknowledgedWork() async throws {
        for effect in ["capture", "backup", "prepare", "verify", "promote", "retire"] {
            let (store, journal, effects) = try setup(.enableCloudReplacingCloud)
            effects.failedEffect = effect
            do {
                try await StorageTransferCoordinator(store: store, effects: effects.live)
                    .resume(transactionID: journal.transactionID, validateTransfer: {})
                XCTFail("Expected interruption at \(effect)")
            } catch is Interrupted {} catch { throw error }
            XCTAssertTrue(effects.sourceExists)
            XCTAssertNotNil(try store.load())
            try await StorageTransferCoordinator(store: store, effects: effects.live)
                .resume(transactionID: journal.transactionID, validateTransfer: {})
            XCTAssertNil(try store.load())
            XCTAssertFalse(effects.sourceExists)
            XCTAssertEqual(effects.calls.filter { $0 == effect }.count, 2)
            XCTAssertEqual(effects.calls.filter { $0 == "backup" }.count, effect == "backup" ? 2 : 1)
        }
    }

    func testDisableAndCloudAuthorityNeverInvokeRemoteReplacementBackupEffect() async throws {
        for choice in [StorageTransferChoice.disableCloudKeepingCopy, .enableCloudKeepingCloud] {
            let (store, journal, effects) = try setup(choice)
            try await StorageTransferCoordinator(store: store, effects: effects.live)
                .resume(transactionID: journal.transactionID, validateTransfer: {})
            XCTAssertFalse(effects.calls.contains("backup"))
            XCTAssertNil(try store.load())
            XCTAssertEqual(try store.committedSelection()?.selection, journal.destination)
        }
    }

    func testAccountOrGenerationInvalidationAfterSuspensionDoesNotAcknowledgeEffect() async throws {
        let (store, journal, effects) = try setup(.enableCloudReplacingCloud)
        var leaseIsValid = true
        var injected = effects.live
        injected.captureSource = { _ in leaseIsValid = false; return String(repeating: "c", count: 64) }
        do {
            try await StorageTransferCoordinator(store: store, effects: injected)
                .resume(transactionID: journal.transactionID, validateTransfer: {
                    guard leaseIsValid else { throw StorageTransferError.staleTransaction }
                })
            XCTFail("A stale callback must not acknowledge the source")
        } catch let error as StorageTransferError { XCTAssertEqual(error, .staleTransaction) }
        XCTAssertEqual(try store.load()?.phase, .requested)
        XCTAssertTrue(effects.sourceExists)
        XCTAssertFalse(effects.backupAcknowledged)
    }
}
