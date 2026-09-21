import CloudKit
import Foundation
import XCTest
@testable import PomoGem

/// What may, and may not, revoke offline access — exercised end to end over
/// the three pieces the launch host wires together: the boundary resolver that
/// performs the only identity comparison, `CloudOfflineHostPolicy` which
/// classifies its outcome, and the durable receipt that records it.
///
/// A device receipt recovered on 2026-09-21 carried `accountChanged` while the
/// stored binding, the namespace-scoped local state and the store pair all said
/// the account had never moved. Nothing in this chain may reach that state
/// again from anything short of a completed comparison.
@MainActor
final class CloudOfflineRevocationEvidenceTests: XCTestCase {
    private struct Fixture {
        let defaults: UserDefaults
        let state: CloudOfflineAccessState
        let binding: ActiveAccountLocalBinding
        let receipt: CloudOfflineAccessReceipt
    }

    /// Resolve once against a stable account, then record the receipt that
    /// resolution authorizes. This is the state a phone is in after a normal
    /// online launch: a verified baseline bound to exactly this account.
    private func fixture(account: String = "stored-account") async throws -> Fixture {
        let suite = "CloudOfflineRevocationEvidence-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("OfflineRevocation-\(UUID())", isDirectory: true)
            .appendingPathComponent("CloudOffline", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        }
        let state = try CloudOfflineAccessState(directory: directory)
        let binding = try await resolver(defaults: defaults, identities: [account])
            .resolve().binding
        let receipt = try state.recordVerifiedOnline(binding: binding,
            datasetGenerationID: UUID(), resetBaseline: nil, expectedReceipt: nil)
        XCTAssertNil(CloudOfflineAccessPolicy.blockReason(
            conditions: conditions(binding), receipt: receipt))
        return Fixture(defaults: defaults, state: state, binding: binding, receipt: receipt)
    }

    private func resolver(defaults: UserDefaults, identities: [String]) -> AppleAccountBoundaryResolver {
        AppleAccountBoundaryResolver(defaults: defaults,
            client: RevocationIdentityScript(identities: identities).client, retryDelay: 0)
    }

    private func conditions(_ binding: ActiveAccountLocalBinding) -> CloudOfflineAccessConditions {
        CloudOfflineAccessConditions(selection: .selected(.cloud(binding: binding)),
            mountState: .mounted(.cloud(binding: binding)), hasExactCompleteStorePair: true,
            hasPendingTransfer: false, hasPendingRemoteIntent: false, isSchemaValid: true)
    }

    /// Everything the launch host does with a boundary error: classify it, and
    /// record the classification only when there is one. Returns the reason it
    /// wrote, so a test can assert both the verdict and the file.
    @discardableResult
    private func recordRevocation(for error: Error, _ f: Fixture) throws -> CloudOfflineRevocationReason? {
        guard let reason = CloudOfflineHostPolicy.revocationReason(for: error) else { return nil }
        try f.state.revoke(binding: f.binding, reason: reason)
        return reason
    }

    // MARK: - A bare account-state notification

    /// `.CKAccountChanged` is posted for sign-in and sign-out, for iCloud
    /// being switched on or off for this app, for token refreshes and for
    /// availability transitions. It carries no identity. The host's only
    /// legitimate reaction is to close the boundary and resolve again — and
    /// when that resolution reports the same account, the receipt that
    /// authorizes offline use must come out of it untouched.
    func testAnAccountStateNotificationThatReVerifiesToTheSameAccountLeavesTheReceiptIntact() async throws {
        let f = try await fixture()
        let resolved = try await resolver(defaults: f.defaults, identities: ["stored-account"])
            .resolve(expectedBinding: f.binding)
        XCTAssertEqual(resolved.binding, f.binding)
        XCTAssertNil(CloudOfflineHostPolicy.revocationReason(for: CancellationError()))
        let after = try XCTUnwrap(f.state.load())
        XCTAssertEqual(after, f.receipt, "Re-verification that found nothing must not write a new revision")
        XCTAssertNil(after.revocation)
        XCTAssertNil(CloudOfflineAccessPolicy.blockReason(
            conditions: conditions(f.binding), receipt: after),
            "Offline use stays available after a notification that proved nothing")
    }

    /// The same notification when the account really did change. The reason
    /// written is the one the comparison produced, and it is durable.
    func testAnAccountStateNotificationThatReVerifiesToAnotherAccountRevokesAsAMismatch() async throws {
        let f = try await fixture()
        do {
            _ = try await resolver(defaults: f.defaults, identities: ["replacement-account"])
                .resolve(expectedBinding: f.binding)
            XCTFail("A different Apple Account must not reuse the stored binding")
        } catch {
            XCTAssertEqual(try recordRevocation(for: error, f), .accountMismatch)
        }
        let after = try XCTUnwrap(f.state.load())
        XCTAssertEqual(after.revocation, .accountMismatch)
        XCTAssertEqual(CloudOfflineAccessPolicy.blockReason(
            conditions: conditions(f.binding), receipt: after), .revoked(.accountMismatch))
        // Everything the receipt knew about the local copy survives the
        // revocation, so a later verified online launch can restore it.
        XCTAssertEqual(after.binding, f.receipt.binding)
        XCTAssertEqual(after.origin, f.receipt.origin)
        XCTAssertEqual(after.datasetGenerationID, f.receipt.datasetGenerationID)
        XCTAssertNotEqual(after.revisionID, f.receipt.revisionID)
    }

    // MARK: - An identity read that disagreed with itself

    /// The proof is repeated, and the repeat is what is compared. Same
    /// account: the launch proceeds and the receipt is never touched.
    func testAnUnstableIdentityThatSettlesOnTheStoredAccountNeverTouchesTheReceipt() async throws {
        let f = try await fixture()
        let resolved = try await resolver(defaults: f.defaults,
            identities: ["stored-account", "noise-account", "stored-account", "stored-account"])
            .resolve(expectedBinding: f.binding)
        XCTAssertEqual(resolved.binding, f.binding)
        XCTAssertEqual(try f.state.load(), f.receipt)
    }

    /// Two proofs that both disagreed with themselves. The launch still fails
    /// closed, but the failure is transient: it has no revocation reason, so
    /// the receipt survives and the offline copy stays eligible.
    func testAnIdentityThatNeverAgreesWithItselfFailsWithoutRevokingOfflineAccess() async throws {
        let f = try await fixture()
        do {
            _ = try await resolver(defaults: f.defaults,
                identities: ["stored-account", "noise-one", "noise-two", "noise-three"])
                .resolve(expectedBinding: f.binding)
            XCTFail("An unusable identity proof cannot authorize a mount")
        } catch let error as AppleAccountBoundaryResolutionError {
            guard case let .verification(failure) = error else {
                return XCTFail("Expected a verification failure, got \(error)")
            }
            XCTAssertEqual(failure.kind, .identityUnstable)
            XCTAssertNil(try recordRevocation(for: error, f),
                "A proof that compared nothing to the stored binding cannot revoke")
            XCTAssertFalse(CloudOfflineHostPolicy.allowsOfflineFallback(after: error),
                "The launch route stays fail-closed; only the receipt is spared")
        }
        let after = try XCTUnwrap(f.state.load())
        XCTAssertEqual(after, f.receipt)
        XCTAssertNil(CloudOfflineAccessPolicy.blockReason(
            conditions: conditions(f.binding), receipt: after),
            "The user keeps the offline door that a false revocation had closed")
    }

    /// The repeat agreeing on a different account is a real mismatch, and is
    /// treated exactly like one that was stable from the first read.
    func testAnUnstableIdentityThatSettlesOnAnotherAccountStillRevokesAsAMismatch() async throws {
        let f = try await fixture()
        do {
            _ = try await resolver(defaults: f.defaults,
                identities: ["stored-account", "noise-account", "replacement-account", "replacement-account"])
                .resolve(expectedBinding: f.binding)
            XCTFail("A confirmed different Apple Account must be rejected")
        } catch {
            XCTAssertEqual(error as? AppleAccountBoundaryResolutionError, .blocked(.accountMismatch))
            XCTAssertEqual(try recordRevocation(for: error, f), .accountMismatch)
        }
        XCTAssertEqual(try f.state.load()?.revocation, .accountMismatch)
    }

    /// A signed-out or managed-restricted account is a positive statement
    /// about account state, not an ambiguous read. Those still revoke.
    func testSignedOutAndRestrictedAccountsStillRevokeUnchanged() async throws {
        for (status, reason) in [(CKAccountStatus.noAccount, CloudOfflineRevocationReason.noAccount),
                                 (.restricted, .restricted)] {
            let f = try await fixture()
            let resolver = AppleAccountBoundaryResolver(defaults: f.defaults,
                client: RevocationIdentityScript(identities: ["stored-account"], status: status).client,
                retryDelay: 0)
            do {
                _ = try await resolver.resolve(expectedBinding: f.binding)
                XCTFail("\(status) cannot authorize a mount")
            } catch {
                XCTAssertEqual(try recordRevocation(for: error, f), reason)
            }
            XCTAssertEqual(try f.state.load()?.revocation, reason)
        }
    }
}

/// Replies to `userRecordID` in order, repeating the last entry. Two adjacent
/// entries that differ reproduce one proof reading two identities.
private actor RevocationIdentityScript {
    private let identities: [String]
    private let status: CKAccountStatus
    private var calls = 0

    init(identities: [String], status: CKAccountStatus = .available) {
        self.identities = identities
        self.status = status
    }

    nonisolated var client: CloudAccountVerificationClient {
        CloudAccountVerificationClient(accountStatus: { await self.currentStatus() },
            userRecordID: { await self.next() }, probePrivateDatabase: { })
    }

    private func currentStatus() -> CKAccountStatus { status }

    private func next() -> CKRecord.ID {
        calls += 1
        return CKRecord.ID(recordName: identities[min(calls - 1, identities.count - 1)])
    }
}
