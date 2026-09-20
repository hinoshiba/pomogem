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

    // MARK: - Cross-scope evidence

    private func scope(_ environment: StorageTransferCloudEnvironment) -> StorageTransferCloudScope {
        StorageTransferCloudScope(environment: environment,
                                  containerIdentifier: "iCloud.com.hinoshiba.pomogem")
    }

    /// The receipt a build reads is chosen by file name, so a receipt filed
    /// under the OTHER environment is invisible to `loadAdmission`. Without it
    /// being fed in as evidence, `decide` would enrol - and enrolling is what
    /// authorizes the host to mirror this device's existing store into a
    /// database that never held it.
    func testAReceiptFiledUnderAnotherEnvironmentRefusesInsteadOfEnroling() throws {
        let binding = try binding()
        let foreign = StorageTransferDatasetAdmission(binding: binding,
            datasetGenerationID: UUID(), cloudScope: scope(.development))
        XCTAssertEqual(StorageTransferAdmissionPolicy.decide(found: nil, binding: binding,
            scope: scope(.production), serverGenerationID: nil, otherScopeReceipts: [foreign]),
            .refuse(.cloudEnvironmentMismatch))
        XCTAssertEqual(StorageTransferAdmissionPolicy.decide(found: nil, binding: binding,
            scope: scope(.production), serverGenerationID: UUID(), otherScopeReceipts: [foreign]),
            .refuse(.cloudEnvironmentMismatch))
    }

    /// The legacy, unscoped receipt is read as `.unknown`, so it is not a
    /// receipt "for this environment" either: a proven sibling still speaks.
    func testAnUnscopedReceiptDoesNotSuppressTheSiblingEvidence() throws {
        let binding = try binding()
        let legacy = StorageTransferDatasetAdmission(binding: binding, datasetGenerationID: UUID())
        let foreign = StorageTransferDatasetAdmission(binding: binding,
            datasetGenerationID: UUID(), cloudScope: scope(.development))
        XCTAssertEqual(StorageTransferAdmissionPolicy.decide(found: legacy, binding: binding,
            scope: scope(.production), serverGenerationID: nil, otherScopeReceipts: [foreign]),
            .refuse(.cloudEnvironmentMismatch))
    }

    /// And the converse: a receipt that already names THIS scope is
    /// authoritative for this database, so a leftover sibling cannot block a
    /// device that is correctly enrolled here.
    func testAProvenReceiptForThisScopeIgnoresSiblings() throws {
        let binding = try binding()
        let generation = UUID()
        let mine = StorageTransferDatasetAdmission(binding: binding,
            datasetGenerationID: generation, cloudScope: scope(.production))
        let foreign = StorageTransferDatasetAdmission(binding: binding,
            datasetGenerationID: UUID(), cloudScope: scope(.development))
        XCTAssertEqual(StorageTransferAdmissionPolicy.decide(found: mine, binding: binding,
            scope: scope(.production), serverGenerationID: generation, otherScopeReceipts: [foreign]),
            .admitted)
    }

    /// An unknown side never accuses a known one, in either direction, so a
    /// build that cannot prove its own environment raises nothing new.
    func testAnUnknownScopeOnEitherSideNeverAccuses() throws {
        let binding = try binding()
        let unscopedSibling = StorageTransferDatasetAdmission(binding: binding, datasetGenerationID: UUID())
        XCTAssertEqual(StorageTransferAdmissionPolicy.decide(found: nil, binding: binding,
            scope: scope(.production), serverGenerationID: nil, otherScopeReceipts: [unscopedSibling]),
            .enrol)
        let scopedSibling = StorageTransferDatasetAdmission(binding: binding,
            datasetGenerationID: UUID(), cloudScope: scope(.development))
        XCTAssertEqual(StorageTransferAdmissionPolicy.decide(found: nil, binding: binding,
            scope: .unknown, serverGenerationID: nil, otherScopeReceipts: [scopedSibling]),
            .enrol)
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

    /// The host switch, as it stands. `presentDatasetRefresh` is the sole
    /// writer of `storageTransferRefreshGenerationID` and the sole producer of
    /// `launchState = .datasetRefresh`, and only `.datasetRefreshRequired`
    /// reaches it. Everything else becomes the generic blocked screen.
    func testTheLaunchRouteMirrorsTheHostSwitch() {
        XCTAssertEqual(CloudOfflineHostPolicy.launchRoute(for: .relaunchRequired), .relaunch)
        XCTAssertEqual(CloudOfflineHostPolicy.launchRoute(for: .remoteRecoveryRequired), .remoteRecovery)
        XCTAssertEqual(CloudOfflineHostPolicy.launchRoute(for: .datasetRefreshRequired), .datasetRefresh)
        for error in [StorageTransferRuntimeError.datasetReplacedRemotely, .cloudLineageUnavailable,
                      .localLedgerMissing, .cloudEnvironmentMismatch, .leftoverLocalStores,
                      .cloudCopyStillPending, .recoveryNeedsReview] {
            XCTAssertEqual(CloudOfflineHostPolicy.launchRoute(for: error), .blocked,
                           "\(error) has no arm of its own in the host switch yet")
        }
    }

    /// The invariant that makes the split safe to ship before the host is
    /// wired: a refusal whose presentation CARRIES 「iCloudから再取得」 must
    /// still reach the screen that can produce it. Any new taxonomy state that
    /// forgets this recreates the permanent dead end the split was meant to end.
    func testEveryRemedyCarryingRefusalStillReachesTheRefreshScreen() {
        // The legacy name is the one the host already routes; it is the target
        // of the shim, not a subject of it.
        XCTAssertEqual(CloudOfflineHostPolicy.launchRoutableRefusal(.datasetRefreshRequired),
                       .datasetRefreshRequired)
        XCTAssertEqual(CloudOfflineHostPolicy.launchRoute(for: .datasetRefreshRequired), .datasetRefresh)

        for error in [StorageTransferRuntimeError.datasetReplacedRemotely,
                      .cloudLineageUnavailable, .localLedgerMissing, .cloudEnvironmentMismatch] {
            let routable = CloudOfflineHostPolicy.launchRoutableRefusal(error)
            guard CloudOfflineHostPolicy.datasetLineageBlock(for: error)?.offersRemoteDataset == true else {
                XCTAssertEqual(routable, error, "\(error) offers no remedy and keeps its own copy")
                XCTAssertEqual(CloudOfflineHostPolicy.launchRoute(for: routable), .blocked)
                continue
            }
            XCTAssertEqual(CloudOfflineHostPolicy.launchRoute(for: routable), .datasetRefresh,
                           "\(error) carries an in-app remedy and must keep reaching it")
        }
    }

    /// ROOT-CAUSE §6.2. A refusal may not promise an action no screen in this
    /// build can offer: `startCloudLineageFromDevice` exists but is behind a
    /// closed policy bit with no entry point, and the blocked screen's only
    /// actions are retry, offline use and support.
    func testNoRefusalPromisesAnActionThisBuildCannotOffer() {
        for error in [StorageTransferRuntimeError.datasetRefreshRequired, .datasetReplacedRemotely,
                      .cloudLineageUnavailable, .localLedgerMissing, .cloudEnvironmentMismatch,
                      .leftoverLocalStores] {
            let text = error.localizedDescription
            for promise in ["iCloudを使い始める", "iCloudを置き換える", "再取得"] {
                XCTAssertFalse(text.contains(promise),
                    "\(error) promises 「\(promise)」, which no screen in this build offers")
            }
        }
    }
}
