import CloudKit
import CryptoKit
import Foundation
import XCTest
@testable import PomoGem

/// device-02 / launch-02. The identity checks around the reset-history read
/// no longer make a zone-list request each: the read between them is the
/// network proof. These tests pin that nothing the checks proved was lost.
@MainActor
final class CloudLaunchProofTests: XCTestCase {
    private final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private var _identities: [CKRecord.ID] = []
        var status: CKAccountStatus = .available
        var reads: [Result<[ActivityResetSnapshot], Error>] = []
        let identity = CKRecord.ID(recordName: "synthetic-history-account")

        var calls: [String] { lock.withLock { _calls } }
        func log(_ call: String) { lock.withLock { _calls.append(call) } }
        func setIdentities(_ values: [CKRecord.ID]) { lock.withLock { _identities = values } }
        func nextIdentity() -> CKRecord.ID {
            lock.withLock { _identities.isEmpty ? identity : _identities.removeFirst() }
        }
        func nextRead() throws -> [ActivityResetSnapshot] {
            let next: Result<[ActivityResetSnapshot], Error> = lock.withLock {
                reads.isEmpty ? .success([]) : reads.removeFirst()
            }
            return try next.get()
        }

        var accountClient: CloudAccountVerificationClient {
            CloudAccountVerificationClient(
                accountStatus: { self.log("status"); return self.status },
                userRecordID: { self.log("identity"); return self.nextIdentity() },
                probePrivateDatabase: { self.log("zone-probe") })
        }
    }

    private struct Fixture {
        let defaults: UserDefaults
        let binding: ActiveAccountLocalBinding
        let script: Script
    }

    private func fixture() throws -> Fixture {
        let suite = "CloudLaunchProof-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let script = Script()
        let id = script.identity
        let data = Data([CloudSyncConfiguration.synchronizedDataContainerIdentifier,
            id.zoneID.ownerName, id.zoneID.zoneName, id.recordName].joined(separator: "\u{0}").utf8)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                                                              accountFingerprint: fingerprint))
        return Fixture(defaults: defaults, binding: binding, script: script)
    }

    private func verify(_ f: Fixture) async throws {
        try await CloudActivityHistoryIdentityCheck.verify(binding: f.binding,
            accountClient: f.script.accountClient, defaults: f.defaults, retryDelay: 0)
    }

    private func marker(_ sequence: Int) -> ActivityResetSnapshot {
        ActivityResetSnapshot(id: UUID(), epochID: UUID(), sequence: sequence,
                              resetAt: Date(timeIntervalSinceReferenceDate: 800_000_000), writerDeviceID: "device")
    }

    func testTheIdentityCheckMakesNoNetworkRequestOfItsOwn() async throws {
        let f = try fixture()
        try await verify(f)
        XCTAssertEqual(f.script.calls, ["status", "identity", "identity"],
                       "Account status and the identity, compared with the binding; no zone-list probe")
    }

    func testAnAccountThatIsNotAvailableFailsTheCheck() async throws {
        let f = try fixture()
        f.script.status = .noAccount
        do {
            try await verify(f)
            XCTFail("A signed-out account must fail the check")
        } catch let AppleAccountBoundaryResolutionError.verification(failure) {
            XCTAssertEqual(failure.kind, .noAccount)
            XCTAssertEqual(CloudOfflineHostPolicy.revocationReason(for: AppleAccountBoundaryResolutionError.verification(failure)),
                           .noAccount, "Still an identity verdict for the host")
        }
    }

    func testAStableDifferentAccountIsAMismatch() async throws {
        let f = try fixture()
        let other = CKRecord.ID(recordName: "someone-else")
        f.script.setIdentities([other, other, other, other])
        do {
            try await verify(f)
            XCTFail("Another account must never pass")
        } catch AppleAccountBoundaryResolutionError.blocked(.accountMismatch) {
            // expected
        }
    }

    func testAnIdentityThatDisagreesWithItselfIsRetriedThenFailsWithoutAccusingTheAccount() async throws {
        let f = try fixture()
        let other = CKRecord.ID(recordName: "someone-else")
        f.script.setIdentities([f.script.identity, other, f.script.identity, other])
        do {
            try await verify(f)
            XCTFail("Two disagreeing reads are not a proof")
        } catch let AppleAccountBoundaryResolutionError.verification(failure) {
            XCTAssertEqual(failure.kind, .identityUnstable)
            XCTAssertNil(CloudOfflineHostPolicy.revocationReason(for: AppleAccountBoundaryResolutionError.verification(failure)))
        }
    }

    /// The whole history check: identity before, the read (the only network
    /// request), identity after — with the mount validated between steps and
    /// the read committed only once the check after it passed.
    func testEachHistoryCheckIsIdentityReadIdentityAndCommitsLast() async throws {
        let f = try fixture()
        let script = f.script
        let defaults = f.defaults
        let client = CloudActivityHistoryClient(verifyAccount: { binding in
            try await CloudActivityHistoryIdentityCheck.verify(binding: binding,
                accountClient: script.accountClient, defaults: defaults, retryDelay: 0)
        }, readHistory: { _ in
            script.log("markers")
            return CloudActivityHistoryMarkerRead(markers: [], commit: { script.log("commit") })
        })
        let preflight = CloudActivityHistoryPreflight(client: client, timeout: 5, pollInterval: 0.01)
        try await preflight.verifyExistingReplicaBeforeMirroring(recordedBaseline: .observed(nil),
            expectedBinding: f.binding, readCurrentLocalMarker: { nil }, validateMount: {})
        try await preflight.run(expectedBinding: f.binding, validateMount: {}, localMarker: { nil })
        let oneCheck = ["status", "identity", "identity", "markers", "status", "identity", "identity", "commit"]
        XCTAssertEqual(script.calls, oneCheck + oneCheck,
                       "Two history checks per launch, each with a single network request")
    }

    func testAReadIsNeverCommittedWhenTheCheckAfterItFails() async throws {
        let f = try fixture()
        let script = f.script
        let remote = marker(1)
        let client = CloudActivityHistoryClient(verifyAccount: { _ in
            script.log("verify")
            if script.calls.filter({ $0 == "verify" }).count == 2 {
                throw AppleAccountBoundaryResolutionError.blocked(.accountMismatch)
            }
        }, readHistory: { _ in
            CloudActivityHistoryMarkerRead(markers: [remote], commit: { script.log("commit") })
        })
        let preflight = CloudActivityHistoryPreflight(client: client, timeout: 5, pollInterval: 0.01)
        do {
            try await preflight.run(expectedBinding: f.binding, validateMount: {}, localMarker: { nil })
            XCTFail("An identity change across the read must fail the check")
        } catch AppleAccountBoundaryResolutionError.blocked(.accountMismatch) {
            // expected
        }
        XCTAssertFalse(script.calls.contains("commit"), "A doubtful read never becomes the next starting point")
    }

    func testTheRoundTripLedgerOnlyCountsOperations() {
        let before = CloudKitRoundTripLedger.snapshot()
        CloudKitRoundTripLedger.record(.controlFetch)
        CloudKitRoundTripLedger.record(.accountProbe)
        CloudKitRoundTripLedger.record(.controlFetch)
        let delta = CloudKitRoundTripLedger.snapshot() - before
        XCTAssertEqual(delta.total, 3)
        XCTAssertEqual(delta.counts[.controlFetch], 2)
        XCTAssertEqual(delta.summary, "accountProbe=1 controlFetch=2 historyZoneList=0 historyZoneChanges=0")
    }
}
