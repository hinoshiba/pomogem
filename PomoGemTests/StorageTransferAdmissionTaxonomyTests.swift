import Foundation
import XCTest
@testable import PomoGem

/// L1 / P0-1. `StorageTransferRuntimeError.datasetRefreshRequired` used to be
/// raised by an `Equatable` comparison of the WHOLE admission struct, which
/// made four unrelated states indistinguishable and let the copy claim another
/// device had replaced the iCloud data even when no other device existed.
/// These tests pin the replacement classification exhaustively, as a pure
/// function, so the runtime and the launch host can never drift apart again.
final class StorageTransferAdmissionTaxonomyTests: XCTestCase {
    private let account = String(repeating: "e", count: 64)

    private func binding() throws -> ActiveAccountLocalBinding {
        try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                accountFingerprint: account))
    }

    private func decide(found: StorageTransferDatasetAdmission?,
                        binding: ActiveAccountLocalBinding,
                        scope: StorageTransferCloudScope = .unknown,
                        server: UUID?) -> StorageTransferAdmissionDecision {
        StorageTransferAdmissionPolicy.decide(found: found, binding: binding,
                                              scope: scope, serverGenerationID: server)
    }

    // MARK: - The four states

    /// Both sides carry a generation and they differ: the only shape for which
    /// "the iCloud data was replaced" is actually true.
    func testTwoDifferentGenerationsAreAReplacement() throws {
        let binding = try binding()
        let found = StorageTransferDatasetAdmission(binding: binding, datasetGenerationID: UUID())
        XCTAssertEqual(decide(found: found, binding: binding, server: UUID()),
                       .refuse(.datasetReplacedRemotely))
    }

    /// The device recorded a generation and the server reports none. This is
    /// the reported defect: `nil` is an authoritative "there is no transfer
    /// ledger here", not "a different record took its place".
    func testARecordedGenerationAgainstNoServerLineageIsNotAReplacement() throws {
        let binding = try binding()
        let found = StorageTransferDatasetAdmission(binding: binding, datasetGenerationID: UUID())
        XCTAssertEqual(decide(found: found, binding: binding, server: nil),
                       .refuse(.cloudLineageUnavailable))
    }

    /// A device admitted while the server had no lineage, meeting a server that
    /// now has one. Something really did publish a dataset, so this stays a
    /// replacement rather than a lineage-unavailable explanation.
    func testEnrolledWithoutALineageAndMeetingOneIsAReplacement() throws {
        let binding = try binding()
        let found = StorageTransferDatasetAdmission(binding: binding, datasetGenerationID: nil)
        XCTAssertEqual(decide(found: found, binding: binding, server: UUID()),
                       .refuse(.datasetReplacedRemotely))
    }

    func testMatchingGenerationsAreAdmittedAndWriteNothing() throws {
        let binding = try binding()
        let generation = UUID()
        let found = StorageTransferDatasetAdmission(binding: binding, datasetGenerationID: generation)
        XCTAssertEqual(decide(found: found, binding: binding, server: generation), .admitted)
        XCTAssertEqual(decide(found: StorageTransferDatasetAdmission(binding: binding,
            datasetGenerationID: nil), binding: binding, server: nil), .admitted)
    }

    func testNoReceiptEnrols() throws {
        XCTAssertEqual(decide(found: nil, binding: try binding(), server: UUID()), .enrol)
    }

    /// The one arm of the old whole-struct comparison that was never about
    /// lineage. It is structurally unreachable and stays fail-closed under the
    /// legacy error, so it is obvious it is not part of the new taxonomy.
    func testABindingDifferenceKeepsTheLegacyRefusal() throws {
        let mine = try binding()
        let foreign = try XCTUnwrap(ActiveAccountLocalBinding(namespace: mine.namespace,
            accountFingerprint: String(repeating: "f", count: 64)))
        let found = StorageTransferDatasetAdmission(binding: foreign, datasetGenerationID: nil)
        XCTAssertEqual(decide(found: found, binding: mine, server: nil),
                       .refuse(.datasetRefreshRequired))
    }

    // MARK: - Copy

    /// ROOT-CAUSE §6.2: no refusal in this taxonomy may claim how many devices
    /// exist. The control record carries no writer identity, so the app cannot
    /// tell its own committed generation from anybody else's.
    func testNoLineageRefusalClaimsADeviceCount() {
        let errors: [StorageTransferRuntimeError] = [
            .datasetRefreshRequired, .datasetReplacedRemotely, .cloudLineageUnavailable,
            .localLedgerMissing, .cloudEnvironmentMismatch, .leftoverLocalStores
        ]
        for error in errors {
            let text = error.localizedDescription
            XCTAssertFalse(text.isEmpty, "\(error) must have Japanese copy")
            for claim in ["別の端末", "他の端末", "別のiPhone", "2台", "複数の端末"] {
                XCTAssertFalse(text.contains(claim),
                               "\(error) must not claim a device count: \(claim)")
            }
        }
    }

    /// The states that mean "nothing was deleted" say so, because the screen
    /// the user actually saw offered no way to verify it.
    func testTheNonDestructiveStatesSayNothingWasDeleted() {
        for error in [StorageTransferRuntimeError.cloudLineageUnavailable,
                      .cloudEnvironmentMismatch, .datasetRefreshRequired] {
            XCTAssertTrue(error.localizedDescription.contains("削除"),
                          "\(error) must state what was NOT deleted")
        }
    }

    /// L4 / P1-5: leftover local stores ask for a clean-up instead of borrowing
    /// the replacement sentence.
    func testLeftoverLocalStoresAsksForACleanUp() {
        let text = StorageTransferRuntimeError.leftoverLocalStores.localizedDescription
        XCTAssertTrue(text.contains("残って"))
        XCTAssertFalse(text.contains("iCloudのデータが別の記録に置き換え"))
    }

    // MARK: - Host routing

    /// Every lineage refusal still offers the offline route, exactly as the
    /// single collapsed error did, so splitting it cannot strand a launch.
    func testEveryLineageRefusalStillOffersTheStorageTransferRecovery() {
        for error in [StorageTransferRuntimeError.datasetRefreshRequired,
                      .datasetReplacedRemotely, .cloudLineageUnavailable,
                      .localLedgerMissing, .cloudEnvironmentMismatch] {
            XCTAssertEqual(CloudOfflineHostPolicy.recoveryKind(after: error), .storageTransfer,
                           "\(error) must keep the storage-transfer recovery offer")
        }
    }

    func testTheHostRoutingTableIsTotalOverTheLineageStates() {
        XCTAssertEqual(CloudOfflineHostPolicy.datasetLineageBlock(for: StorageTransferRuntimeError.datasetReplacedRemotely),
                       .remoteDatasetOffer)
        XCTAssertEqual(CloudOfflineHostPolicy.datasetLineageBlock(for: StorageTransferRuntimeError.cloudLineageUnavailable),
                       .lineageUnavailable)
        XCTAssertEqual(CloudOfflineHostPolicy.datasetLineageBlock(for: StorageTransferRuntimeError.cloudEnvironmentMismatch),
                       .environmentMismatch)
        XCTAssertEqual(CloudOfflineHostPolicy.datasetLineageBlock(for: StorageTransferRuntimeError.localLedgerMissing),
                       .localLedgerMissing)
        // Not lineage decisions.
        XCTAssertNil(CloudOfflineHostPolicy.datasetLineageBlock(for: StorageTransferRuntimeError.leftoverLocalStores))
        XCTAssertNil(CloudOfflineHostPolicy.datasetLineageBlock(for: StorageTransferRuntimeError.remoteRecoveryRequired))
        XCTAssertNil(CloudOfflineHostPolicy.datasetLineageBlock(for: StorageTransferRuntimeError.datasetRefreshRequired))
    }
}
