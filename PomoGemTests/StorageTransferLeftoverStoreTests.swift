import Foundation
import XCTest
@testable import PomoGem

/// L4 / P1-5. `requireNoArtifacts` was shared by five call sites and raised
/// `datasetRefreshRequired` at all of them, so merely switching iCloud ON from
/// Settings - on a device that had used iCloud before, gone local-only, and
/// kept that namespace's cloud store files - reported that another device had
/// replaced the iCloud data. Nothing had happened on the server at all.
///
/// `begin()` itself resolves a real Apple Account boundary and needs a live
/// `ModelContext`, so it cannot be driven from a unit test; the precondition it
/// calls is exercised directly instead, with the exact error `begin()` passes.
@MainActor
final class StorageTransferLeftoverStoreTests: XCTestCase {

    /// Creates the cloud store artifacts for a namespace that has never
    /// existed, so nothing in the test host container can collide, and removes
    /// them again afterwards.
    private func makeCloudStore(_ namespace: AccountDataNamespace) throws {
        let urls = try PersistenceStoreTopology.persistentStoreURLs(for: .cloudKit,
                                                                    accountNamespace: namespace)
        let storeURL = try XCTUnwrap(urls.first)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: storeURL.path,
            contents: Data("leftover cloud store".utf8)))
        addTeardownBlock {
            for artifact in urls.flatMap({ PersistenceStoreArtifactLayout.artifacts(for: $0) }) {
                try? FileManager.default.removeItem(at: artifact)
            }
        }
    }

    private func binding(_ namespace: AccountDataNamespace) throws -> ActiveAccountLocalBinding {
        try XCTUnwrap(ActiveAccountLocalBinding(namespace: namespace,
            accountFingerprint: String(repeating: "3", count: 64)))
    }

    /// The Settings path: `begin()` passes `.leftoverLocalStores`, whose copy
    /// asks for a clean-up and never mentions the iCloud dataset changing.
    func testTheSettingsPreconditionReportsLeftoverLocalStores() throws {
        let namespace = AccountDataNamespace()
        try makeCloudStore(namespace)
        XCTAssertThrowsError(try StorageTransferStoreArtifactPrecondition.requireNone(
            selection: .cloud(binding: try binding(namespace)), error: .leftoverLocalStores)) { error in
            XCTAssertEqual(error as? StorageTransferRuntimeError, .leftoverLocalStores)
        }
    }

    /// The preflight enrolment path keeps its own, different meaning: the local
    /// ledger never recorded the generation the server is currently serving.
    func testThePreflightEnrolmentPreconditionReportsAMissingLocalLedger() throws {
        let namespace = AccountDataNamespace()
        try makeCloudStore(namespace)
        XCTAssertThrowsError(try StorageTransferStoreArtifactPrecondition.requireNone(
            selection: .cloud(binding: try binding(namespace)), error: .localLedgerMissing)) { error in
            XCTAssertEqual(error as? StorageTransferRuntimeError, .localLedgerMissing)
        }
    }

    /// The two meanings must not be the same value, or the split is cosmetic.
    func testTheTwoPreconditionsAreDistinctAndNeitherClaimsARemoteReplacement() {
        XCTAssertNotEqual(StorageTransferRuntimeError.leftoverLocalStores,
                          StorageTransferRuntimeError.localLedgerMissing)
        for error in [StorageTransferRuntimeError.leftoverLocalStores, .localLedgerMissing] {
            let text = error.localizedDescription
            XCTAssertFalse(text.contains("別の端末"))
            XCTAssertFalse(text.contains("置き換えられました"),
                           "\(error) is about local files, not a remote replacement")
        }
        XCTAssertTrue(StorageTransferRuntimeError.leftoverLocalStores.localizedDescription
            .contains("整理"), "The clean-up request must actually be stated")
    }

    /// A namespace with no artifacts passes, so the precondition is a real
    /// check rather than an unconditional refusal.
    func testAnUntouchedNamespacePassesThePrecondition() throws {
        XCTAssertNoThrow(try StorageTransferStoreArtifactPrecondition.requireNone(
            selection: .cloud(binding: try binding(AccountDataNamespace())),
            error: .leftoverLocalStores))
    }
}
