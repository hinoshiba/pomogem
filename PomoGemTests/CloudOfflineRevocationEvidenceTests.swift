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

    // MARK: - Retracting a revocation that nothing ever proved

    /// The escape hatch for a phone already in the bad state. A launch that
    /// verifies the identity and resolves it to the stored binding retracts
    /// the `accountChanged` record, so offline use is available again even
    /// though the launch itself may still be blocked further down (a lineage
    /// or transfer preflight can fail long before any mount could clear it).
    func testAConfirmedSameAccountRetractsARevocationNoComparisonEverSupported() async throws {
        let f = try await fixture()
        try f.state.markOfflineOpened(binding: f.binding, conditions: conditions(f.binding))
        let used = try XCTUnwrap(f.state.load())
        try f.state.revoke(binding: f.binding, reason: .accountChanged)
        let revoked = try XCTUnwrap(f.state.load())
        XCTAssertEqual(CloudOfflineAccessPolicy.blockReason(
            conditions: conditions(f.binding), receipt: revoked), .revoked(.accountChanged))

        let resolved = try await resolver(defaults: f.defaults, identities: ["stored-account"])
            .resolve(expectedBinding: f.binding)
        XCTAssertEqual(resolved.binding, f.binding)
        let healed = try XCTUnwrap(f.state.clearRevocationAfterConfirmedIdentity(
            confirmedBinding: resolved.binding))

        XCTAssertNil(healed.revocation)
        XCTAssertNil(CloudOfflineAccessPolicy.blockReason(
            conditions: conditions(f.binding), receipt: healed))
        // Only the revocation goes. The verified baseline the receipt is
        // worth keeping must survive verbatim, including the offline use that
        // makes later history checks mandatory.
        XCTAssertEqual(healed.origin, used.origin)
        XCTAssertEqual(healed.isDatasetGenerationKnown, used.isDatasetGenerationKnown)
        XCTAssertEqual(healed.datasetGenerationID, used.datasetGenerationID)
        XCTAssertEqual(healed.resetBaseline, used.resetBaseline)
        XCTAssertTrue(healed.wasUsedOffline)
        XCTAssertNotEqual(healed.revisionID, revoked.revisionID)
        XCTAssertEqual(try CloudOfflineAccessState(directory: f.state.directory).load(), healed)
        // Nothing left to retract, and the operation is not a way to mint a
        // second clean revision out of an already-valid receipt.
        XCTAssertNil(try f.state.clearRevocationAfterConfirmedIdentity(confirmedBinding: f.binding))
        XCTAssertEqual(try f.state.load(), healed)
    }

    /// The reasons a comparison or a positive account state produced are not
    /// retractable by any number of confirmed identities: they still require
    /// a successful cloud mount through `recordVerifiedOnline`.
    func testAConfirmedSameAccountNeverRetractsAMismatchSignOutOrRestriction() async throws {
        for reason in [CloudOfflineRevocationReason.accountMismatch, .noAccount, .restricted] {
            let f = try await fixture()
            try f.state.revoke(binding: f.binding, reason: reason)
            let revoked = try XCTUnwrap(f.state.load())
            let resolved = try await resolver(defaults: f.defaults, identities: ["stored-account"])
                .resolve(expectedBinding: f.binding)
            XCTAssertNil(try f.state.clearRevocationAfterConfirmedIdentity(
                confirmedBinding: resolved.binding), "\(reason)")
            XCTAssertEqual(try f.state.load(), revoked, "\(reason)")
            XCTAssertEqual(CloudOfflineAccessPolicy.blockReason(
                conditions: conditions(f.binding), receipt: revoked), .revoked(reason))
            XCTAssertFalse(CloudOfflineAccessPolicy.isRetractableByConfirmedIdentity(reason))
        }
        XCTAssertTrue(CloudOfflineAccessPolicy.isRetractableByConfirmedIdentity(.accountChanged))
    }

    /// A confirmed identity for a DIFFERENT account retracts nothing — the
    /// receipt belongs to the account it names, and this operation is not a
    /// path for one account to reopen another's local copy.
    func testAConfirmedIdentityForAnotherAccountRetractsNothing() async throws {
        let f = try await fixture()
        try f.state.revoke(binding: f.binding, reason: .accountChanged)
        let revoked = try XCTUnwrap(f.state.load())
        let others = [
            try XCTUnwrap(ActiveAccountLocalBinding(namespace: f.binding.namespace,
                accountFingerprint: String(repeating: "b", count: 64))),
            try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                accountFingerprint: f.binding.accountFingerprint))
        ]
        for other in others {
            XCTAssertNil(try f.state.clearRevocationAfterConfirmedIdentity(confirmedBinding: other))
            XCTAssertEqual(try f.state.load(), revoked)
        }
    }

    /// A revocation written before any online check has no baseline to return
    /// to. Retracting it would leave a receipt claiming nothing at all, so it
    /// is left exactly as it is and the ordinary online path still applies.
    func testARevocationRecordedBeforeAnyOnlineCheckIsNotRetractable() async throws {
        let f = try await fixture()
        let directory = f.state.directory.deletingLastPathComponent()
            .appendingPathComponent("Second-\(UUID())", isDirectory: true)
            .appendingPathComponent("CloudOffline", isDirectory: true)
        let fresh = try CloudOfflineAccessState(directory: directory)
        try fresh.revoke(binding: f.binding, reason: .accountChanged)
        let revoked = try XCTUnwrap(fresh.load())
        XCTAssertEqual(revoked.origin, .revokedWithoutBaseline)
        XCTAssertNil(try fresh.clearRevocationAfterConfirmedIdentity(confirmedBinding: f.binding))
        XCTAssertEqual(try fresh.load(), revoked)
    }

    // MARK: - The route that opens the local copy without asking

    /// The device sequence this branch has to survive: an offline session
    /// bound to account A, a `.CKAccountChanged` while it is live, and an
    /// offline launch immediately afterwards. Not revoking the receipt means
    /// the launch can no longer be stopped by the receipt, so the movement
    /// itself has to close the offline route until a resolution answers it.
    /// `openOfflineSession` performs no identity work of any kind: everything
    /// it checks — the receipt, the mount state, the store pair, the transfer
    /// gates — is a local record of a PREVIOUS check.
    func testAnAccountStateNotificationClosesTheOfflineRouteUntilTheBoundaryIsResolved() async throws {
        let f = try await fixture()
        let paths: [Bool?] = [true, false, nil]
        // Before the notification, an offline network path is enough.
        XCTAssertTrue(CloudOfflineHostPolicy.prefersOfflineLaunch(explicitOnlineRetry: false,
            requestedOfflineFallback: false, networkIsOffline: true,
            hasUnresolvedAccountStateMovement: false))

        // The notification itself writes nothing, and leaves a receipt that
        // still authorizes offline use on its own terms.
        XCTAssertEqual(CloudOfflineHostPolicy.reactionToAccountStateNotification(
            selection: .selected(.cloud(binding: f.binding))), .quiesceOnly)
        XCTAssertEqual(try f.state.load(), f.receipt)
        XCTAssertNil(CloudOfflineAccessPolicy.blockReason(
            conditions: conditions(f.binding), receipt: f.receipt))

        // So the movement is the only thing left holding the door, and it
        // holds it against every route into the local copy.
        for path in paths {
            for fallback in [false, true] {
                XCTAssertFalse(CloudOfflineHostPolicy.prefersOfflineLaunch(explicitOnlineRetry: false,
                    requestedOfflineFallback: fallback, networkIsOffline: path,
                    hasUnresolvedAccountStateMovement: true))
            }
            XCTAssertEqual(CloudOfflineHostPolicy.timeoutRecoveryAction(cloudMirrorWasOpened: false,
                hasExistingStore: true, containersRetired: true, sceneIsActive: true,
                hasUnresolvedAccountStateMovement: true), .retryOnline)
        }
        XCTAssertNotNil(CloudOfflineHostPolicy.unresolvedAccountMovementMessage(
            after: CloudLaunchDeadlineError.expired, hasUnresolvedAccountStateMovement: true,
            offlineCopyWouldOtherwiseBeEligible: true),
            "A launch that withdrew the offline door has to say so")

        // A completed resolution is what reopens it. The same account changes
        // nothing else: the receipt is still byte-equal afterwards.
        let resolved = try await resolver(defaults: f.defaults, identities: ["stored-account"])
            .resolve(expectedBinding: f.binding)
        XCTAssertEqual(resolved.binding, f.binding)
        XCTAssertEqual(try f.state.load(), f.receipt)
        XCTAssertTrue(CloudOfflineHostPolicy.prefersOfflineLaunch(explicitOnlineRetry: false,
            requestedOfflineFallback: false, networkIsOffline: true,
            hasUnresolvedAccountStateMovement: false))
    }

    /// The other account really being signed in ends the same launch with the
    /// reason a comparison produced, so the door that the movement closed
    /// stays closed for a durable reason rather than a volatile one.
    func testTheSameSequenceForAnotherAccountEndsInADurableMismatch() async throws {
        let f = try await fixture()
        XCTAssertEqual(CloudOfflineHostPolicy.reactionToAccountStateNotification(
            selection: .selected(.cloud(binding: f.binding))), .quiesceOnly)
        do {
            _ = try await resolver(defaults: f.defaults, identities: ["replacement-account"])
                .resolve(expectedBinding: f.binding)
            XCTFail("A different Apple Account must not reuse the stored binding")
        } catch {
            XCTAssertEqual(try recordRevocation(for: error, f), .accountMismatch)
        }
        let after = try XCTUnwrap(f.state.load())
        XCTAssertEqual(CloudOfflineAccessPolicy.blockReason(
            conditions: conditions(f.binding), receipt: after), .revoked(.accountMismatch))
        XCTAssertFalse(CloudOfflineAccessPolicy.isRetractableByConfirmedIdentity(.accountMismatch))
    }

    // MARK: - The launch step that performs the retraction

    /// One step: the retraction and the recomputation of the offline door.
    /// The door has to flip within the same launch attempt, because the
    /// attempt that confirms the identity is usually the one that is then
    /// blocked by the lineage preflight.
    func testTheLaunchStepRetractsAndReopensTheOfflineDoorInOneStep() async throws {
        let f = try await fixture()
        try f.state.markOfflineOpened(binding: f.binding, conditions: conditions(f.binding))
        try f.state.revoke(binding: f.binding, reason: .accountChanged)
        XCTAssertFalse(offlineDoorIsOpen(f))

        let resolved = try await resolver(defaults: f.defaults, identities: ["stored-account"])
            .resolve(expectedBinding: f.binding)
        let outcome = CloudOfflineLaunchRecovery(expectedBinding: f.binding,
            resolvedBinding: resolved.binding)
            .run(state: f.state, isEligible: { self.offlineDoorIsOpen(f, binding: $0) })
        XCTAssertEqual(outcome.retractedReason, .accountChanged)
        XCTAssertTrue(outcome.offlineCopyIsEligible)
        XCTAssertFalse(outcome.failed)
        XCTAssertNil(try f.state.load()?.revocation)
        XCTAssertTrue(try XCTUnwrap(f.state.load()).wasUsedOffline)

        // Idempotent, and never a way to open a door the receipt keeps shut.
        let second = CloudOfflineLaunchRecovery(expectedBinding: f.binding,
            resolvedBinding: resolved.binding)
            .run(state: f.state, isEligible: { self.offlineDoorIsOpen(f, binding: $0) })
        XCTAssertNil(second.retractedReason)
        XCTAssertTrue(second.offlineCopyIsEligible)
        for reason in [CloudOfflineRevocationReason.accountMismatch, .noAccount, .restricted] {
            try f.state.revoke(binding: f.binding, reason: reason)
            let refused = CloudOfflineLaunchRecovery(expectedBinding: f.binding,
                resolvedBinding: resolved.binding)
                .run(state: f.state, isEligible: { self.offlineDoorIsOpen(f, binding: $0) })
            XCTAssertNil(refused.retractedReason, "\(reason)")
            XCTAssertFalse(refused.offlineCopyIsEligible, "\(reason)")
            XCTAssertEqual(try f.state.load()?.revocation, reason)
        }
    }

    /// A launch that resolved a DIFFERENT account than the receipt names
    /// retracts nothing, whichever way the step is called.
    func testTheLaunchStepRetractsNothingForAnAccountTheReceiptDoesNotName() async throws {
        let f = try await fixture()
        try f.state.revoke(binding: f.binding, reason: .accountChanged)
        let revoked = try XCTUnwrap(f.state.load())
        let other = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
            accountFingerprint: String(repeating: "c", count: 64)))
        for recovery in [CloudOfflineLaunchRecovery(expectedBinding: f.binding, resolvedBinding: other),
                         CloudOfflineLaunchRecovery(expectedBinding: other, resolvedBinding: other),
                         CloudOfflineLaunchRecovery(expectedBinding: nil, resolvedBinding: f.binding)] {
            let outcome = recovery.run(state: f.state, isEligible: { _ in false })
            XCTAssertNil(outcome.retractedReason)
            XCTAssertEqual(try f.state.load(), revoked)
        }
    }

    /// The order is the feature. The transfer and lineage preflights can end
    /// a launch long before any cloud mount is reached, and a mount is the
    /// only other way a revocation is ever cleared — so the step is shaped so
    /// that the preflight runs inside it, after the retraction. A preflight
    /// that throws still leaves the phone with its offline door open.
    func testTheRetractionHappensBeforeTheLaunchStepThatCanBlockTheLaunch() async throws {
        let f = try await fixture()
        try f.state.markOfflineOpened(binding: f.binding, conditions: conditions(f.binding))
        try f.state.revoke(binding: f.binding, reason: .accountChanged)
        let resolved = try await resolver(defaults: f.defaults, identities: ["stored-account"])
            .resolve(expectedBinding: f.binding)

        var order: [String] = []
        var recorded: CloudOfflineLaunchRecovery.Outcome?
        do {
            try await CloudOfflineLaunchRecovery(expectedBinding: f.binding,
                resolvedBinding: resolved.binding)
                .run(state: f.state, isEligible: { self.offlineDoorIsOpen(f, binding: $0) },
                     record: { order.append("retraction"); recorded = $0 }) {
                    order.append("preflight")
                    // The launch is about to be blocked; the door must already
                    // be open by the time that happens.
                    XCTAssertNil(try f.state.load()?.revocation)
                    XCTAssertTrue(self.offlineDoorIsOpen(f))
                    throw StorageTransferRuntimeError.datasetRefreshRequired
                }
            XCTFail("The preflight failure must reach the launch")
        } catch {
            XCTAssertEqual(error as? StorageTransferRuntimeError, .datasetRefreshRequired)
        }
        XCTAssertEqual(order, ["retraction", "preflight"])
        XCTAssertEqual(recorded?.retractedReason, .accountChanged)
        XCTAssertEqual(recorded?.offlineCopyIsEligible, true)
        XCTAssertTrue(offlineDoorIsOpen(f))
    }

    // MARK: - Receipts written by the build already on phones

    /// Nothing in production writes `accountChanged` any more; the case exists
    /// so that receipts ALREADY on phones keep decoding, and the retraction
    /// exists to heal exactly those. That makes the raw value on disk part of
    /// the file format: the receipt decoder is strict, so an unrecognized
    /// revocation string does not degrade to nil — it throws, and a throwing
    /// receipt can no longer be read, repaired or replaced.
    func testAReceiptWrittenByTheShippedBuildDecodesBlocksAndHeals() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("OfflineRevocationBytes-\(UUID())", isDirectory: true)
            .appendingPathComponent("CloudOffline", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        }
        let state = try CloudOfflineAccessState(directory: directory)
        let namespace = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
        let fingerprint = String(repeating: "7a", count: 32)
        let bytes = Data("""
        {"accountFingerprint":"\(fingerprint)",\
        "datasetGenerationID":"7C3F1B0E-2E4A-4E2B-9E7C-0B5B9A1D6C21",\
        "formatVersion":1,"hasVerifiedOnlineBaseline":true,"isDatasetGenerationKnown":true,\
        "namespace":"\(namespace)","origin":"verifiedOnline",\
        "resetBaseline":null,"revisionID":"1D9A6D0C-4F2E-4C8B-8E0B-7B3D2A5C9E10",\
        "revocation":"accountChanged","wasUsedOffline":true}
        """.utf8)
        try bytes.write(to: directory.appendingPathComponent("access-v1.json"))

        let receipt = try XCTUnwrap(state.load(), "A receipt already on a phone must still decode")
        XCTAssertEqual(receipt.revocation, .accountChanged)
        XCTAssertEqual(receipt.origin, .verifiedOnline)
        XCTAssertTrue(receipt.wasUsedOffline)
        let binding = receipt.binding
        XCTAssertEqual(binding.namespace.rawValue, namespace)
        XCTAssertEqual(CloudOfflineAccessPolicy.blockReason(
            conditions: CloudOfflineAccessConditions(selection: .selected(.cloud(binding: binding)),
                mountState: .mounted(.cloud(binding: binding)), hasExactCompleteStorePair: true,
                hasPendingTransfer: false, hasPendingRemoteIntent: false, isSchemaValid: true),
            receipt: receipt), .revoked(.accountChanged))

        let healed = try XCTUnwrap(state.clearRevocationAfterConfirmedIdentity(confirmedBinding: binding))
        XCTAssertNil(healed.revocation)
        XCTAssertEqual(healed.datasetGenerationID, receipt.datasetGenerationID)
        XCTAssertTrue(healed.wasUsedOffline)

        // The same spelling has to come back out of the encoder, or a receipt
        // written by this build would not be readable by the one before it.
        try state.revoke(binding: binding, reason: .accountChanged)
        let written = try String(decoding: Data(contentsOf: directory
            .appendingPathComponent("access-v1.json")), as: UTF8.self)
        XCTAssertTrue(written.contains("\"revocation\":\"accountChanged\""), written)
    }

    private func offlineDoorIsOpen(_ f: Fixture, binding: ActiveAccountLocalBinding? = nil) -> Bool {
        let binding = binding ?? f.binding
        guard let receipt = try? f.state.load() else { return false }
        return CloudOfflineAccessPolicy.blockReason(
            conditions: conditions(binding), receipt: receipt) == nil
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
