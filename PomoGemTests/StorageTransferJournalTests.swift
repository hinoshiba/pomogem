import Foundation
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferJournalTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private let otherDigest = String(repeating: "b", count: 64)

    private func request(_ choice: StorageTransferChoice) throws -> StorageTransferJournal {
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(
            namespace: AccountDataNamespace(), accountFingerprint: digest))
        let local = PersistenceDeploymentSelection.localOnly(namespace: AccountDataNamespace())
        let cloud = PersistenceDeploymentSelection.cloud(binding: binding)
        return try StorageTransferJournal(choice: choice,
            source: choice == .disableCloudKeepingCopy ? cloud : local,
            destination: choice == .disableCloudKeepingCopy ? local : cloud,
            cloudBinding: binding)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageTransferJournalTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRelaunchAtEveryCheckpointPreservesChoiceAndDoesNotPrematurelyCommit() throws {
        for choice in StorageTransferChoice.allCases {
            let root = try directory()
            let store = StorageTransferJournalStore(directory: root)
            var journal = try request(choice)
            try store.begin(journal)
            for phase in StorageTransferJournal.Phase.allCases.dropFirst() {
                let reopened = StorageTransferJournalStore(directory: root)
                XCTAssertEqual(try reopened.load(), journal)
                if phase == .selectionCommitted { try reopened.commitSelection(for: journal) }
                let next = try journal.advancing(to: phase,
                    sourceDigest: phase == .sourceSaved ? digest : nil,
                    destinationDigest: phase == .destinationSaved ? digest : nil,
                    remoteRecoveryTransactionID: phase == .recoveryCopySaved && choice.replacesCloud
                        ? journal.transactionID : nil)
                try reopened.save(next, replacing: journal)
                journal = next
                XCTAssertEqual(try reopened.load(), journal)
                XCTAssertEqual(try reopened.committedSelection() != nil, phase >= .selectionCommitted)
            }
            try store.finish(journal)
            XCTAssertNil(try store.load())
            XCTAssertEqual(try store.committedSelection()?.selection, journal.destination)
        }
    }

    func testReplacementCannotAuthorizeDeletionWithoutAcknowledgedMatchingRecoveryCopy() throws {
        let initial = try request(.enableCloudReplacingCloud)
        let saved = try initial.advancing(to: .sourceSaved, sourceDigest: digest)
        XCTAssertThrowsError(try saved.advancing(to: .recoveryCopySaved))
        XCTAssertThrowsError(try saved.advancing(to: .recoveryCopySaved,
                                                remoteRecoveryTransactionID: UUID()))
        let backedUp = try saved.advancing(to: .recoveryCopySaved,
                                           remoteRecoveryTransactionID: initial.transactionID)
        XCTAssertTrue(backedUp.permitsCancellation)
        XCTAssertFalse(try backedUp.advancing(to: .preparingDestination).permitsCancellation)
    }

    func testDisableAndCloudAuthorityCannotAcquireRemoteDeletionProof() throws {
        for choice in [StorageTransferChoice.disableCloudKeepingCopy, .enableCloudKeepingCloud] {
            let saved = try request(choice).advancing(to: .sourceSaved, sourceDigest: digest)
            XCTAssertThrowsError(try saved.advancing(to: .recoveryCopySaved,
                                                    remoteRecoveryTransactionID: saved.transactionID))
        }
    }

    func testImportCancellationRetainsCopiesOnlyBeforePromotionForEveryChoiceAndRefresh() throws {
        let prior = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: digest))
        let next = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: digest))
        let refresh = try StorageTransferJournal(choice: .enableCloudKeepingCloud,
            source: .cloud(binding: prior), destination: .cloud(binding: next), cloudBinding: next)
        let requests = try StorageTransferChoice.allCases.map { try request($0) }
        for initial in requests + [refresh] {
            var journal = initial
            for phase in StorageTransferJournal.Phase.allCases {
                if phase != .requested {
                    journal = try journal.advancing(to: phase,
                        sourceDigest: phase == .sourceSaved ? digest : nil,
                        destinationDigest: phase == .destinationSaved ? digest : nil,
                        remoteRecoveryTransactionID: phase == .recoveryCopySaved && journal.choice.replacesCloud
                            ? journal.transactionID : nil)
                }
                let mayRetain = !journal.choice.replacesCloud
                    && [StorageTransferJournal.Phase.preparingDestination, .destinationSaved].contains(phase)
                XCTAssertEqual(journal.retainsImportOnCancellation, mayRetain, "Choice: \(journal.choice), phase: \(phase)")
                XCTAssertEqual(journal.permitsCancellation, phase < .preparingDestination || mayRetain)
                let reopened = try JSONDecoder().decode(StorageTransferJournal.self, from: JSONEncoder().encode(journal))
                try reopened.validate()
                XCTAssertEqual(reopened.retainsImportOnCancellation, mayRetain)
                XCTAssertEqual(reopened, journal)
                if mayRetain {
                    XCTAssertNil(reopened.remoteRecoveryTransactionID,
                        "Retaining an imported copy never grants remote replacement authority")
                }
            }
        }
    }

    func testStaleOrDuplicateCallbackCannotAdvanceJournalOrChangeSnapshot() throws {
        let store = StorageTransferJournalStore(directory: try directory())
        let initial = try request(.disableCloudKeepingCopy)
        try store.begin(initial)
        let saved = try initial.advancing(to: .sourceSaved, sourceDigest: digest)
        try store.save(saved, replacing: initial)
        XCTAssertThrowsError(try store.save(saved, replacing: initial))
        XCTAssertThrowsError(try store.begin(request(.enableCloudKeepingCloud)))
        XCTAssertThrowsError(try saved.advancing(to: .recoveryCopySaved, sourceDigest: otherDigest))
        XCTAssertThrowsError(try saved.advancing(to: .destinationVerified))
        XCTAssertEqual(try store.load(), saved)
    }

    func testCopyMismatchCannotPublishDestination() throws {
        var journal = try request(.disableCloudKeepingCopy)
        journal = try journal.advancing(to: .sourceSaved, sourceDigest: digest)
        journal = try journal.advancing(to: .recoveryCopySaved)
        journal = try journal.advancing(to: .preparingDestination)
        journal = try journal.advancing(to: .destinationSaved, destinationDigest: otherDigest)
        XCTAssertThrowsError(try journal.advancing(to: .destinationVerified))
        XCTAssertThrowsError(try StorageTransferCommittedSelection(journal: journal))
    }

    func testCorruptOrOversizedJournalNeverLooksLikeNoPendingTransfer() throws {
        for bytes in [Data("not-json".utf8), Data(repeating: 0, count: 32_769)] {
            let root = try directory()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try bytes.write(to: root.appendingPathComponent("pending-v1.json"))
            XCTAssertThrowsError(try StorageTransferJournalStore(directory: root).load())
        }
    }

    func testSymlinkIncludingDanglingJournalNeverReadsOrOverwritesTarget() throws {
        let root = try directory()
        let outside = try directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("pending-v1.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = StorageTransferJournalStore(directory: root)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.begin(request(.disableCloudKeepingCopy)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }

    func testRefreshUsesNewNamespaceOfSameAccountAndCannotAcquireCloudDeletionAuthority() throws {
        let source = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: digest))
        let destination = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: digest))
        let journal = try StorageTransferJournal(choice: .enableCloudKeepingCloud,
            source: .cloud(binding: source), destination: .cloud(binding: destination), cloudBinding: destination)
        XCTAssertFalse(journal.choice.replacesCloud)
        let saved = try journal.advancing(to: .sourceSaved, sourceDigest: digest)
        XCTAssertThrowsError(try saved.advancing(to: .recoveryCopySaved, remoteRecoveryTransactionID: journal.transactionID))
        let wrong = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: otherDigest))
        XCTAssertThrowsError(try StorageTransferJournal(choice: .enableCloudKeepingCloud,
            source: .cloud(binding: source), destination: .cloud(binding: wrong), cloudBinding: wrong))
    }

    func testUnknownJournalFieldsCannotAuthorizeNamespaceOrMountTransition() throws {
        let root = try directory()
        let store = StorageTransferJournalStore(directory: root)
        try store.begin(request(.enableCloudKeepingCloud))
        let url = root.appendingPathComponent("pending-v1.json")
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        data["unknownFutureAuthority"] = true
        try JSONSerialization.data(withJSONObject: data).write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try StorageTransferAccountNamespaceAuthority.read(from: store))
    }

    func testAccountAndModeMismatchAreRejectedBeforeJournalCreation() throws {
        let initial = try request(.disableCloudKeepingCopy)
        let otherAccount = try XCTUnwrap(ActiveAccountLocalBinding(
            namespace: initial.cloudBinding.namespace, accountFingerprint: otherDigest))
        XCTAssertThrowsError(try StorageTransferJournal(choice: initial.choice,
            source: initial.source, destination: initial.destination, cloudBinding: otherAccount))
        XCTAssertThrowsError(try StorageTransferJournal(choice: .enableCloudReplacingCloud,
            source: initial.source, destination: initial.destination, cloudBinding: initial.cloudBinding))
    }
}
