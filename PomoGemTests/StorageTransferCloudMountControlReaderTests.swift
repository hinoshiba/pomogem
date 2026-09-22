import CloudKit
import CryptoKit
import Foundation
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferCloudMountControlReaderTests: XCTestCase {
    private struct Fixture {
        let defaults: UserDefaults
        let binding: ActiveAccountLocalBinding
        let script: MountControlReadScript
        let control: StorageTransferRecoveryControl
    }

    private func fixture() throws -> Fixture {
        let suite = "CloudMountControlReader-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let script = MountControlReadScript()
        let identity = script.identity
        let data = Data([CloudSyncConfiguration.synchronizedDataContainerIdentifier,
            identity.zoneID.ownerName, identity.zoneID.zoneName, identity.recordName].joined(separator: "\u{0}").utf8)
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let binding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: fingerprint))
        let manifest = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: fingerprint,
            payload: Data("synthetic mount admission".utf8))
        let control = try StorageTransferRecoveryControl(manifest: manifest).cancelling()
        script.responses = [.success(try response(control))]
        return Fixture(defaults: defaults, binding: binding, script: script, control: control)
    }

    private func response(_ control: StorageTransferRecoveryControl) throws -> StorageTransferRecoveryCloudRecord {
        .init(record: try StorageTransferRecoveryCloudCodec.control(control, name: StorageTransferRecoverySchema.controlRecordName),
              changeTag: "synthetic-server-revision", systemFieldsProof: "synthetic-server-archive")
    }

    private func reader(_ f: Fixture, timeout: TimeInterval = 1, center: NotificationCenter = .default,
                        store: StorageTransferJournalStore? = nil) -> StorageTransferCloudMountControlReader {
        .init(client: f.script.client, defaults: f.defaults, transferJournalStore: store,
              notificationCenter: center, timeout: timeout, retryDelay: 0)
    }

    private func transportFailure(_ code: CKError.Code) -> Error {
        CloudStorageTransferCloudError.cloud(.classify(CKError(code), stage: .privateDatabase))
    }

    private func assertVerification(_ operation: () async throws -> Void,
                                    kind: CloudAccountVerificationFailure.Kind,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected account/network refusal", file: file, line: line) }
        catch let AppleAccountBoundaryResolutionError.verification(failure) {
            XCTAssertEqual(failure.kind, kind, file: file, line: line)
        } catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    func testControlFetchIsTheOnlyNetworkProbeWithIdentityOnBothSides() async throws {
        let f = try fixture()
        let actual = try await reader(f).read(expectedBinding: f.binding, validateAccess: {})
        XCTAssertEqual(actual, f.control)
        XCTAssertEqual(f.script.calls, ["status", "identity", "control", "identity"])
        XCTAssertEqual(f.script.requestedIDs, [StorageTransferRecoveryCloudCodec.controlID])
        XCTAssertEqual(f.script.standaloneProbes, 0)
        XCTAssertEqual(PersistenceDeploymentState.load(defaults: f.defaults), .unselected)
    }

    func testExactAuthoritativeAbsenceStillNeedsBothIdentityObservations() async throws {
        let f = try fixture()
        f.script.responses = [.success(nil)]
        let actual = try await reader(f).read(expectedBinding: f.binding, validateAccess: {})
        XCTAssertNil(actual)
        XCTAssertEqual(f.script.calls, ["status", "identity", "control", "identity"])
        XCTAssertEqual(f.script.standaloneProbes, 0)
    }

    func testUnavailableAccountStopsBeforeControlRead() async throws {
        let f = try fixture()
        f.script.statusValue = .noAccount
        await assertVerification({
            _ = try await self.reader(f).read(expectedBinding: f.binding, validateAccess: {})
        }, kind: .noAccount)
        XCTAssertEqual(f.script.calls, ["status"])
        XCTAssertTrue(f.script.requestedIDs.isEmpty)
    }

    func testNetworkPermissionConfigurationAndAuthenticationErrorsNeverBecomeAbsence() async throws {
        let cases: [(CKError.Code, CloudAccountVerificationFailure.Kind, Int)] = [
            (.networkFailure, .networkUnavailable, 2), (.permissionFailure, .permission, 1),
            (.badContainer, .configuration, 1), (.notAuthenticated, .noAccount, 1),
            (.accountTemporarilyUnavailable, .temporarilyUnavailable, 1)]
        for (code, kind, expectedReads) in cases {
            let f = try fixture()
            f.script.responses = Array(repeating: .failure(transportFailure(code)), count: expectedReads)
            await assertVerification({
                _ = try await self.reader(f).read(expectedBinding: f.binding, validateAccess: {})
            }, kind: kind)
            XCTAssertEqual(f.script.requestedIDs.count, expectedReads)
            XCTAssertEqual(f.script.standaloneProbes, 0)
        }
    }

    func testTransientFetchRetryRepeatsTheWholeIdentityProofWithoutExtraZoneProbe() async throws {
        let f = try fixture()
        f.script.responses = [.failure(transportFailure(.networkFailure)), .success(try response(f.control))]
        let actual = try await reader(f).read(expectedBinding: f.binding, validateAccess: {})
        XCTAssertEqual(actual, f.control)
        XCTAssertEqual(f.script.calls, ["status", "identity", "control", "status", "identity", "control", "identity"])
        XCTAssertEqual(f.script.standaloneProbes, 0)
    }

    func testServerBackoffIsPreservedWithoutAnImmediateSecondControlRead() async throws {
        let f = try fixture()
        let failure = CloudAccountVerificationFailure.classify(
            CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 60]), stage: .privateDatabase)
        f.script.responses = [.failure(CloudStorageTransferCloudError.cloud(failure))]
        do {
            _ = try await reader(f).read(expectedBinding: f.binding, validateAccess: {})
            XCTFail("Server backoff must leave launch pending without another probe")
        } catch let AppleAccountBoundaryResolutionError.verification(actual) {
            XCTAssertEqual(actual, failure)
        }
        XCTAssertEqual(f.script.requestedIDs.count, 1)
        XCTAssertEqual(f.script.standaloneProbes, 0)
    }

    func testRetryCannotReturnControlFromAnEarlierUnverifiedAttempt() async throws {
        let f = try fixture()
        f.script.identityResults = [.success(f.script.identity), .failure(CKError(.networkFailure)),
                                    .success(f.script.identity), .success(f.script.identity)]
        f.script.responses = [.success(try response(f.control)), .success(nil)]
        let actual = try await reader(f).read(expectedBinding: f.binding, validateAccess: {})
        XCTAssertNil(actual)
        XCTAssertEqual(f.script.requestedIDs.count, 2)
        XCTAssertEqual(f.script.calls, ["status", "identity", "control", "identity", "status", "identity", "control", "identity"])
    }

    /// Two identity reads that disagreed with each other say the READ was
    /// unusable, not that another Apple Account signed in: the whole proof,
    /// control fetch included, is repeated once before anything is concluded.
    func testIdentityThatDisagreedWithItselfRepeatsTheWholeProofInsteadOfAccusingTheAccount() async throws {
        let f = try fixture()
        f.script.identityResults = [.success(f.script.identity),
                                    .success(CKRecord.ID(recordName: "noise-synthetic-account")),
                                    .success(f.script.identity), .success(f.script.identity)]
        f.script.responses = [.success(try response(f.control)), .success(try response(f.control))]
        let actual = try await reader(f).read(expectedBinding: f.binding, validateAccess: {})
        XCTAssertEqual(actual, f.control)
        XCTAssertEqual(f.script.requestedIDs.count, 2)
        XCTAssertEqual(f.script.calls, ["status", "identity", "control", "identity",
                                        "status", "identity", "control", "identity"])
    }

    func testIdentityThatNeverAgreesWithItselfStaysATransientVerificationFailure() async throws {
        let f = try fixture()
        f.script.identityResults = [.success(f.script.identity),
                                    .success(CKRecord.ID(recordName: "noise-synthetic-account")),
                                    .success(CKRecord.ID(recordName: "second-noise-account")),
                                    .success(CKRecord.ID(recordName: "third-noise-account"))]
        f.script.responses = [.success(try response(f.control)), .success(try response(f.control))]
        await assertVerification({
            _ = try await self.reader(f).read(expectedBinding: f.binding, validateAccess: {})
        }, kind: .identityUnstable)
        XCTAssertEqual(f.script.requestedIDs.count, 2)
    }

    /// The fail-closed half stays exactly where it was: a proof that agrees
    /// with itself on a DIFFERENT account is a mismatch, not a transient read.
    func testAStableDifferentIdentityRemainsAConfirmedAccountMismatch() async throws {
        let f = try fixture()
        let other = CKRecord.ID(recordName: "different-synthetic-account")
        f.script.identityResults = Array(repeating: .success(other), count: 4)
        f.script.responses = [.success(try response(f.control)), .success(try response(f.control))]
        do {
            _ = try await reader(f).read(expectedBinding: f.binding, validateAccess: {})
            XCTFail("A confirmed different account must not return the stored account's control")
        } catch let error as AppleAccountBoundaryResolutionError {
            XCTAssertEqual(error, .blocked(.accountMismatch))
            XCTAssertEqual(CloudOfflineHostPolicy.revocationReason(for: error), .accountMismatch)
        }
    }

    func testSelectedAccountMismatchAndControlPayloadMismatchRemainDistinct() async throws {
        let f = try fixture()
        let wrongBinding = try XCTUnwrap(ActiveAccountLocalBinding(namespace: f.binding.namespace,
            accountFingerprint: String(repeating: "b", count: 64)))
        do {
            _ = try await reader(f).read(expectedBinding: wrongBinding, validateAccess: {})
            XCTFail("A live account mismatch must refuse the selected namespace")
        } catch {
            XCTAssertEqual(error as? AppleAccountBoundaryResolutionError, .blocked(.accountMismatch))
            XCTAssertEqual(CloudOfflineHostPolicy.revocationReason(for: error), .accountMismatch)
        }
        let other = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: wrongBinding.accountFingerprint,
            payload: Data("different record payload".utf8))
        f.script.responses = [.success(try response(StorageTransferRecoveryControl(manifest: other)))]
        do {
            _ = try await reader(f).read(expectedBinding: f.binding, validateAccess: {})
            XCTFail("A control for another account is malformed admission evidence")
        } catch {
            XCTAssertEqual(error as? StorageTransferRecoveryError, .identityMismatch)
            XCTAssertNil(CloudOfflineHostPolicy.revocationReason(for: error), "A record field is not a live account observation")
        }
    }

    func testStrictControlCodecAndServerRevisionValidationAreNotBypassed() async throws {
        for mutation in 0..<5 {
            let f = try fixture()
            let original = try response(f.control)
            let changed: StorageTransferRecoveryCloudRecord
            switch mutation {
            case 0:
                original.record["unexpectedField"] = "unrecognized" as NSString
                changed = original
            case 1:
                original.record["controlSHA256"] = String(repeating: "0", count: 64) as NSString
                changed = original
            case 2:
                let wrong = CKRecord(recordType: original.record.recordType, recordID: CKRecord.ID(recordName: "control-v1"))
                for key in original.record.allKeys() { wrong[key] = original.record[key] }
                changed = .init(record: wrong, changeTag: original.changeTag, systemFieldsProof: original.systemFieldsProof)
            case 3:
                changed = .init(record: original.record, changeTag: "", systemFieldsProof: original.systemFieldsProof)
            default:
                changed = .init(record: original.record, changeTag: original.changeTag, systemFieldsProof: "")
            }
            f.script.responses = [.success(changed)]
            do {
                _ = try await reader(f).read(expectedBinding: f.binding, validateAccess: {})
                XCTFail("Malformed control must not authorize a mount; case \(mutation)")
            } catch { XCTAssertNotNil(error as? StorageTransferRecoveryError) }
            XCTAssertEqual(f.script.requestedIDs.count, 1)
        }
    }

    func testNamespaceAuthorityChangingDuringReadInvalidatesTheResult() async throws {
        let f = try fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MountAuthority-\(UUID())")
        let store = StorageTransferJournalStore(directory: directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let journal = try StorageTransferJournal(choice: .disableCloudKeepingCopy, source: .cloud(binding: f.binding),
            destination: .localOnly(namespace: AccountDataNamespace()), cloudBinding: f.binding)
        f.script.onFetch = { try store.begin(journal) }
        do {
            _ = try await reader(f, store: store).read(expectedBinding: f.binding, validateAccess: {})
            XCTFail("A result cannot survive a changed namespace/transfer authority")
        } catch { XCTAssertEqual(error as? AppleAccountBoundaryResolutionError, .blocked(.invalidStoredRegistry)) }
        XCTAssertEqual(try store.load(), journal)
    }

    func testSceneOrDeadlineInvalidationDuringReadPreservesTheCallerError() async throws {
        let f = try fixture()
        var valid = true
        f.script.onFetch = { valid = false }
        do {
            _ = try await reader(f).read(expectedBinding: f.binding, validateAccess: {
                guard valid else { throw MountControlReadError.expiredLease }
            })
            XCTFail("A successful server read cannot restore a revoked host lease")
        } catch { XCTAssertEqual(error as? MountControlReadError, .expiredLease) }
        XCTAssertEqual(f.script.calls, ["status", "identity", "control"])
    }

    func testAccountNotificationReleasesAHungReadBeforeItsLateCallback() async throws {
        let f = try fixture()
        let center = NotificationCenter()
        let started = expectation(description: "control read suspended")
        let gate = MountControlReadGate(started: started)
        f.script.suspendedFetch = { try await gate.wait() }
        let operation = Task { try await self.reader(f, center: center).read(expectedBinding: f.binding, validateAccess: {}) }
        await fulfillment(of: [started], timeout: 1)
        center.post(name: .CKAccountChanged, object: nil)
        do { _ = try await operation.value; XCTFail("Account notification must revoke the read") }
        catch { XCTAssertEqual(error as? AppleAccountBoundaryResolutionError, .blocked(.accountMismatch)) }
        gate.finish(try response(f.control))
        await Task.yield()
        XCTAssertEqual(f.script.calls, ["status", "identity", "control"])
    }

    func testCancellationAndDeadlineReleaseHungReadsWithoutAcceptingLateValues() async throws {
        for cancel in [false, true] {
            let f = try fixture()
            let started = expectation(description: "control read suspended")
            let gate = MountControlReadGate(started: started)
            f.script.suspendedFetch = { try await gate.wait() }
            let operation = Task { try await self.reader(f, timeout: cancel ? 1 : 0.1)
                .read(expectedBinding: f.binding, validateAccess: {}) }
            await fulfillment(of: [started], timeout: 1)
            if cancel { operation.cancel() }
            do { _ = try await operation.value; XCTFail("Cancelled/expired read must not publish") }
            catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else {
                    let outerTimeout = (error as? CloudStorageTransferCloudError) == .timedOut
                    let verifierTimeout: Bool
                    if case let AppleAccountBoundaryResolutionError.verification(failure) = error {
                        verifierTimeout = failure.kind == .timedOut
                    } else { verifierTimeout = false }
                    XCTAssertTrue(outerTimeout || verifierTimeout)
                }
            }
            gate.finish(try response(f.control))
            await Task.yield()
            XCTAssertEqual(f.script.calls, ["status", "identity", "control"])
        }
    }

    func testRuntimeStillReadsControlTwiceAndRejectsAChangedFinalGeneration() async throws {
        let f = try fixture()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("MountRuntime-\(UUID())", isDirectory: true)
        let directory = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let store = StorageTransferJournalStore(directory: directory)
        let runtime = StorageTransferRuntime(store: store, root: directory)
        // Reach the real control-admission path only after the production
        // directory/intent gate accepts this isolated fixture.
        let pendingIntent = try runtime.pendingRemoteCancellationIntent()
        XCTAssertNil(pendingIntent)
        let newer = try StorageTransferRecoveryManifest(transactionID: UUID(), accountFingerprint: f.binding.accountFingerprint,
            payload: Data("new ordinary mount fence".utf8), previousDatasetGenerationID: UUID())
        f.script.responses = [.success(try response(f.control)), .success(try response(StorageTransferRecoveryControl(manifest: newer).cancelling()))]
        do {
            try await runtime.preflightCloudMount(binding: f.binding, controlClient: f.script.client,
                accountDefaults: f.defaults, validateAccess: {})
            XCTFail("The later dataset observation must invalidate initial admission")
        } catch {
            XCTAssertEqual(error as? StorageTransferRuntimeError, .remoteRecoveryRequired,
                           "Unexpected error type: \(type(of: error))")
        }
        XCTAssertEqual(f.script.requestedIDs, Array(repeating: StorageTransferRecoveryCloudCodec.controlID, count: 2))
        XCTAssertEqual(f.script.standaloneProbes, 0)
        XCTAssertEqual(f.script.calls.count, 8)
    }

    func testRuntimeUsesItsOwnPendingAuthorityBeforeAnyInjectedTransportRead() async throws {
        let f = try fixture()
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("MountRuntimePending-\(UUID())", isDirectory: true)
        let directory = parent.appendingPathComponent("StorageTransfer", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let store = StorageTransferJournalStore(directory: directory)
        let journal = try StorageTransferJournal(choice: .disableCloudKeepingCopy, source: .cloud(binding: f.binding),
            destination: .localOnly(namespace: AccountDataNamespace()), cloudBinding: f.binding)
        try store.begin(journal)
        let runtime = StorageTransferRuntime(store: store, root: directory)
        let pendingIntent = try runtime.pendingRemoteCancellationIntent()
        XCTAssertNil(pendingIntent)
        do {
            try await runtime.preflightCloudMount(binding: f.binding, controlClient: f.script.client,
                accountDefaults: f.defaults, validateAccess: {})
            XCTFail("Custom Runtime journal must gate its own control reader")
        } catch {
            XCTAssertEqual(error as? StorageTransferRuntimeError, .remoteRecoveryRequired,
                           "Unexpected error type: \(type(of: error))")
        }
        XCTAssertTrue(f.script.calls.isEmpty)
        XCTAssertEqual(try store.load(), journal)
    }
}

private enum MountControlReadError: Error, Equatable { case expiredLease }

@MainActor
private final class MountControlReadScript {
    let identity = CKRecord.ID(recordName: "synthetic-mount-account")
    var statusValue: CKAccountStatus = .available
    var identityResults: [Result<CKRecord.ID, Error>] = []
    var responses: [Result<StorageTransferRecoveryCloudRecord?, Error>] = []
    var calls: [String] = []
    var requestedIDs: [CKRecord.ID] = []
    var standaloneProbes = 0
    var onFetch: (() throws -> Void)?
    var suspendedFetch: (() async throws -> StorageTransferRecoveryCloudRecord?)?

    var client: StorageTransferCloudMountControlClient {
        .init(account: .init(accountStatus: { await self.status() }, userRecordID: { try await self.recordID() },
            probePrivateDatabase: { await self.standaloneProbe() },
            containerIdentifier: CloudSyncConfiguration.synchronizedDataContainerIdentifier), fetch: { try await self.fetch($0) })
    }
    func status() -> CKAccountStatus { calls.append("status"); return statusValue }
    func recordID() throws -> CKRecord.ID {
        calls.append("identity")
        return try identityResults.isEmpty ? identity : identityResults.removeFirst().get()
    }
    func standaloneProbe() { standaloneProbes += 1 }
    func fetch(_ id: CKRecord.ID) async throws -> StorageTransferRecoveryCloudRecord? {
        calls.append("control")
        requestedIDs.append(id)
        try onFetch?()
        if let suspendedFetch { return try await suspendedFetch() }
        guard !responses.isEmpty else { throw MountControlReadError.expiredLease }
        return try responses.removeFirst().get()
    }
}

@MainActor
private final class MountControlReadGate {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<StorageTransferRecoveryCloudRecord?, Error>?
    init(started: XCTestExpectation) { self.started = started }
    func wait() async throws -> StorageTransferRecoveryCloudRecord? {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func finish(_ value: StorageTransferRecoveryCloudRecord?) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: value)
    }
}
