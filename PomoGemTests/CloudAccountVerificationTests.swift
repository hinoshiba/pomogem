import CloudKit
import XCTest
@testable import PomoGem

final class CloudAccountVerificationTests: XCTestCase {
    func testUnavailableStatusesDoNotAccessIdentityOrDatabase() async throws {
        for (status, kind) in [
            (CKAccountStatus.noAccount, CloudAccountVerificationFailure.Kind.noAccount),
            (.restricted, .restricted),
            (.temporarilyUnavailable, .temporarilyUnavailable),
            (.couldNotDetermine, .unknown)
        ] {
            let script = CloudVerificationScript(status: status)
            do {
                _ = try await CloudAccountIdentityVerifier.verify(using: script.client)
                XCTFail("Unavailable account must be rejected")
            } catch let failure as CloudAccountVerificationFailure {
                XCTAssertEqual(failure.kind, kind)
                XCTAssertEqual(failure.stage, .accountStatus)
            }
            let calls = await script.calls
            XCTAssertEqual(calls, ["status"])
        }
    }

    func testSuccessfulProofChecksIdentityOnBothSidesOfPrivateDatabaseProbe() async throws {
        let script = CloudVerificationScript()
        let result = try await CloudAccountIdentityVerifier.verify(using: script.client)
        XCTAssertEqual(result.recordName, "test-account")
        let calls = await script.calls
        XCTAssertEqual(calls, ["status", "identity", "probe", "identity"])
    }

    @MainActor
    func testResolverRejectsAccountChangeDuringProofWithoutPersistingSelection() async throws {
        let suite = "CloudAccountVerificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let script = CloudVerificationScript(changesIdentity: true)
        let resolver = AppleAccountBoundaryResolver(defaults: defaults, client: script.client)
        do {
            _ = try await resolver.resolve()
            XCTFail("An identity change cannot authorize any namespace")
        } catch let error as AppleAccountBoundaryResolutionError {
            guard case let .verification(failure) = error else {
                return XCTFail("Expected verification failure")
            }
            XCTAssertEqual(failure.kind, .accountChanged)
            XCTAssertEqual(failure.stage, .identityAfterProbe)
        }
        XCTAssertFalse(AppleAccountBoundaryResolver.hasPersistedRegistryHistory(defaults: defaults))
        XCTAssertEqual(PersistenceDeploymentState.load(defaults: defaults), .unselected)
    }

    @MainActor
    func testResolverUsesExpectedNamespaceAndStillRejectsDifferentAccount() async throws {
        let suite = "CloudAccountVerificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = AppleAccountBoundaryResolver(
            defaults: defaults, client: CloudVerificationScript().client
        )
        let initial = try await resolver.resolve()
        let repeated = try await resolver.resolve(expectedBinding: initial.binding)
        XCTAssertEqual(initial, repeated)
        let other = AppleAccountBoundaryResolver(
            defaults: defaults,
            client: CloudVerificationScript(recordName: "other-test-account").client
        )
        do {
            _ = try await other.resolve(expectedBinding: initial.binding)
            XCTFail("The selected account boundary must remain immutable")
        } catch let error as AppleAccountBoundaryResolutionError {
            XCTAssertEqual(error, .blocked(.accountMismatch))
        }
    }

    func testTransientProbeFailureRetriesOneCompleteIdentityProof() async throws {
        let script = CloudVerificationScript(probeErrors: [CKError(.networkFailure)])
        _ = try await CloudAccountIdentityVerifier.verify(using: script.client, retryDelay: 0)
        let calls = await script.calls
        XCTAssertEqual(calls, ["status", "identity", "probe", "status", "identity", "probe", "identity"])
    }

    func testPersistentTransientFailureStopsAfterSecondAttemptAndKeepsStageAndCode() async throws {
        let script = CloudVerificationScript(probeErrors: [
            CKError(.networkFailure), CKError(.networkFailure), CKError(.networkFailure)
        ])
        do {
            _ = try await CloudAccountIdentityVerifier.verify(using: script.client, retryDelay: 0)
            XCTFail("Persistent failure must not authorize a mount")
        } catch let failure as CloudAccountVerificationFailure {
            XCTAssertEqual(failure.kind, .networkUnavailable)
            XCTAssertEqual(failure.stage, .privateDatabase)
            XCTAssertEqual(failure.cloudKitCode, CKError.networkFailure.rawValue)
        }
        let calls = await script.calls
        XCTAssertEqual(calls.filter { $0 == "probe" }.count, 2)
    }

    func testTemporaryAccountAndLongServerBackoffAreNotAutomaticallyRetried() async throws {
        for error in [
            CKError(.accountTemporarilyUnavailable),
            CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 60.0])
        ] {
            let script = CloudVerificationScript(probeErrors: [error])
            do {
                _ = try await CloudAccountIdentityVerifier.verify(using: script.client, retryDelay: 0)
                XCTFail("CloudKit requested waiting outside the launch attempt")
            } catch is CloudAccountVerificationFailure { }
            let calls = await script.calls
            XCTAssertEqual(calls.filter { $0 == "probe" }.count, 1)
        }
    }

    func testRetryHonorsServerDelayAndRejectsUnboundedValues() {
        for (serverDelay, expected) in [
            (0.25, Optional(0.5)), (2.0, Optional(2.0)),
            (4.0, nil), (.infinity, nil), (.nan, nil)
        ] {
            let failure = CloudAccountVerificationFailure(
                kind: .serviceUnavailable, stage: .privateDatabase, retryAfter: serverDelay
            )
            XCTAssertEqual(failure.automaticRetryDelay(defaultDelay: 0.5), expected)
        }
    }

    func testRepeatedVerificationHonorsServerBackoffUntilExpiry() async throws {
        let clock = CloudVerificationClock()
        let backoff = CloudAccountVerificationBackoff(now: { clock.now })
        let script = CloudVerificationScript(probeErrors: [
            CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 60.0])
        ])
        for remaining in [60.0, 50.0] {
            let client = script.makeClient(backoff: backoff, containerIdentifier: "data")
            do {
                _ = try await CloudAccountIdentityVerifier.verify(using: client, retryDelay: 0)
                XCTFail("Retry must not bypass CloudKit's server backoff")
            } catch let failure as CloudAccountVerificationFailure {
                XCTAssertEqual(failure.kind, .serviceUnavailable)
                XCTAssertEqual(failure.stage, .privateDatabase)
                XCTAssertEqual(failure.retryAfter, remaining)
                XCTAssertTrue(failure.localizedDescription.contains("約\(Int(remaining))秒"))
            }
            let calls = await script.calls
            XCTAssertEqual(calls, ["status", "identity", "probe"])
            clock.advance(by: 10)
        }

        clock.advance(by: 40)
        // A recreated client represents a new launch resolver or Settings
        // monitor. Expiry permits a completely fresh account proof.
        let recreated = script.makeClient(backoff: backoff, containerIdentifier: "data")
        _ = try await CloudAccountIdentityVerifier.verify(using: recreated, retryDelay: 0)
        let calls = await script.calls
        XCTAssertEqual(calls, ["status", "identity", "probe", "status", "identity", "probe", "identity"])
    }

    func testBackoffForOneContainerDoesNotBlockAnother() async throws {
        let clock = CloudVerificationClock()
        let backoff = CloudAccountVerificationBackoff(now: { clock.now })
        await backoff.record(
            CloudAccountVerificationFailure(
                kind: .serviceUnavailable, stage: .privateDatabase, retryAfter: 60
            ),
            for: "data"
        )
        let script = CloudVerificationScript()
        _ = try await CloudAccountIdentityVerifier.verify(using: script.makeClient(
            backoff: backoff, containerIdentifier: "other"
        ))
        let calls = await script.calls
        XCTAssertEqual(calls, ["status", "identity", "probe", "identity"])
        let pending = await backoff.failureIfWaiting(for: "data")
        XCTAssertEqual(pending?.retryAfter, 60)
    }

    func testOverlappingBackoffCannotShortenExistingDeadline() async {
        let clock = CloudVerificationClock()
        let backoff = CloudAccountVerificationBackoff(now: { clock.now })
        await backoff.record(
            CloudAccountVerificationFailure(
                kind: .serviceUnavailable, stage: .privateDatabase, retryAfter: 60
            ),
            for: "data"
        )
        clock.advance(by: 10)
        await backoff.record(
            CloudAccountVerificationFailure(
                kind: .serviceUnavailable, stage: .accountStatus, retryAfter: 1
            ),
            for: "data"
        )
        let pending = await backoff.failureIfWaiting(for: "data")
        XCTAssertEqual(pending?.retryAfter, 50)
        XCTAssertEqual(pending?.stage, .privateDatabase)
    }

    func testInvalidServerBackoffDoesNotCreateAStuckCooldown() async {
        let clock = CloudVerificationClock()
        let backoff = CloudAccountVerificationBackoff(now: { clock.now })
        for delay in [-1.0, 0, .infinity, -.infinity, .nan] {
            await backoff.record(
                CloudAccountVerificationFailure(
                    kind: .serviceUnavailable, stage: .privateDatabase, retryAfter: delay
                ),
                for: "data"
            )
            let pending = await backoff.failureIfWaiting(for: "data")
            XCTAssertNil(pending)
        }
    }

    func testShortServerBackoffStillAllowsOneAutomaticRetry() async throws {
        let backoff = CloudAccountVerificationBackoff()
        let script = CloudVerificationScript(probeErrors: [
            CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 0.02])
        ])
        _ = try await CloudAccountIdentityVerifier.verify(
            using: script.makeClient(backoff: backoff, containerIdentifier: "data"),
            timeout: 2,
            retryDelay: 0
        )
        let calls = await script.calls
        XCTAssertEqual(calls, ["status", "identity", "probe", "status", "identity", "probe", "identity"])
    }

    func testConcurrentBackoffIsCheckedBeforeTheNextCloudKitRequest() async throws {
        let clock = CloudVerificationClock()
        let backoff = CloudAccountVerificationBackoff(now: { clock.now })
        let client = CloudAccountVerificationClient(
            accountStatus: { .available },
            userRecordID: {
                // Another verifier receives throttling while this one's
                // identity request is in flight.
                await backoff.record(
                    CloudAccountVerificationFailure(
                        kind: .serviceUnavailable, stage: .privateDatabase, retryAfter: 60
                    ),
                    for: "data"
                )
                return CKRecord.ID(recordName: "test-account")
            },
            probePrivateDatabase: { XCTFail("The next request must respect concurrent backoff") },
            backoff: backoff,
            containerIdentifier: "data"
        )
        do {
            _ = try await CloudAccountIdentityVerifier.verify(using: client, retryDelay: 0)
            XCTFail("A concurrent server deadline must block the later probe")
        } catch let failure as CloudAccountVerificationFailure {
            XCTAssertEqual(failure.kind, .serviceUnavailable)
            XCTAssertEqual(failure.retryAfter, 60)
        }
    }

    func testActionableCloudKitCodesKeepDistinctRecoveryCategories() {
        let cases: [(CKError.Code, CloudAccountVerificationFailure.Kind)] = [
            (.notAuthenticated, .noAccount),
            (.managedAccountRestricted, .restricted),
            (.accountTemporarilyUnavailable, .temporarilyUnavailable),
            (.networkUnavailable, .networkUnavailable), (.networkFailure, .networkUnavailable),
            (.serviceUnavailable, .serviceUnavailable), (.requestRateLimited, .serviceUnavailable),
            (.zoneBusy, .serviceUnavailable), (.serverResponseLost, .serviceUnavailable),
            (.badContainer, .configuration), (.missingEntitlement, .configuration),
            (.badDatabase, .configuration), (.invalidArguments, .configuration),
            (.incompatibleVersion, .configuration), (.permissionFailure, .permission),
            (.quotaExceeded, .quota), (.internalError, .unknown)
        ]
        for (code, expected) in cases {
            let failure = CloudAccountVerificationFailure.classify(
                CKError(code), stage: .identityBeforeProbe
            )
            XCTAssertEqual(failure.kind, expected)
            XCTAssertEqual(failure.stage, .identityBeforeProbe)
            XCTAssertEqual(failure.cloudKitCode, code.rawValue)
        }
    }

    func testDiagnosticsNeverEchoCloudKitMessageOrUserInfo() {
        let secret = "private-account-record-zone-value"
        let error = CKError(.missingEntitlement, userInfo: [
            NSLocalizedDescriptionKey: secret,
            NSUnderlyingErrorKey: NSError(domain: secret, code: 77),
            "recordName": secret
        ])
        let failure = CloudAccountVerificationFailure.classify(error, stage: .privateDatabase)
        XCTAssertEqual(failure.kind, .configuration)
        XCTAssertEqual(failure.cloudKitCode, CKError.missingEntitlement.rawValue)
        XCTAssertTrue(failure.localizedDescription.contains("iCloudへの接続"))
        XCTAssertTrue(failure.localizedDescription.contains("CloudKit 8"))
        XCTAssertFalse(failure.localizedDescription.contains(secret))
    }

    func testWholeVerificationDeadlineBoundsCancellationUncooperativeAccountLookup() async throws {
        let started = expectation(description: "account status started")
        let gate = CloudVerificationGate(started: started)
        let client = CloudAccountVerificationClient(
            accountStatus: { await gate.wait() },
            userRecordID: { XCTFail("Timeout cannot reach identity"); return CKRecord.ID(recordName: "unused") },
            probePrivateDatabase: { XCTFail("Timeout cannot probe the database") }
        )
        let completed = expectation(description: "deadline completes before callback")
        let task = Task { () -> Result<CKRecord.ID, Error> in
            defer { completed.fulfill() }
            do {
                return .success(try await CloudAccountIdentityVerifier.verify(using: client, timeout: 0.2))
            } catch { return .failure(error) }
        }
        await fulfillment(of: [started], timeout: 2)
        await fulfillment(of: [completed], timeout: 2)
        await gate.release()
        do {
            _ = try await task.value.get()
            XCTFail("The whole proof must time out")
        } catch let failure as CloudAccountVerificationFailure {
            XCTAssertEqual(failure.kind, .timedOut)
            XCTAssertEqual(failure.stage, .verification)
        }
        await gate.release()
    }

    @MainActor
    func testResolverCancellationReturnsBeforeUncooperativeIdentityCallback() async throws {
        let started = expectation(description: "identity started")
        let gate = CloudVerificationGate(started: started)
        let client = CloudAccountVerificationClient(
            accountStatus: { .available },
            userRecordID: {
                _ = await gate.wait()
                return CKRecord.ID(recordName: "late-account")
            },
            probePrivateDatabase: { XCTFail("Cancelled identity cannot probe") }
        )
        let resolver = AppleAccountBoundaryResolver(client: client)
        let completed = expectation(description: "cancellation completes before callback")
        let task = Task { () -> Result<ResolvedAppleAccountBoundary, Error> in
            defer { completed.fulfill() }
            do { return .success(try await resolver.resolve()) }
            catch { return .failure(error) }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [completed], timeout: 2)
        await gate.release()
        do {
            _ = try await task.value.get()
            XCTFail("Cancellation must not return an identity")
        } catch is CancellationError { }
        await gate.release()
    }

    func testCancelledLateCloudKitFailureStillBlocksTheNextVerification() async throws {
        let started = expectation(description: "uncancellable account request started")
        let gate = CloudVerificationGate(started: started)
        let recorded = expectation(description: "late worker records server backoff")
        let clock = CloudVerificationClock(firstRead: recorded)
        let backoff = CloudAccountVerificationBackoff(now: { clock.now })
        let client = CloudAccountVerificationClient(
            accountStatus: {
                _ = await gate.wait()
                throw CKError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 60.0])
            },
            userRecordID: { XCTFail("Cancelled lookup cannot reach identity"); return CKRecord.ID(recordName: "unused") },
            probePrivateDatabase: { XCTFail("Cancelled lookup cannot probe") },
            backoff: backoff,
            containerIdentifier: "data"
        )
        let cancelled = expectation(description: "caller completes before late response")
        let task = Task { () -> Result<CKRecord.ID, Error> in
            defer { cancelled.fulfill() }
            do { return .success(try await CloudAccountIdentityVerifier.verify(using: client)) }
            catch { return .failure(error) }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        do {
            _ = try await task.value.get()
            XCTFail("Caller cancellation must still finish promptly")
        } catch is CancellationError { }

        await gate.release()
        // Wait until the late worker processes its response. The following
        // actor read is serialized after that worker's backoff write.
        await fulfillment(of: [recorded], timeout: 2)
        let pending = await backoff.failureIfWaiting(for: "data")
        XCTAssertEqual(pending?.retryAfter, 60)
        let next = CloudVerificationScript()
        do {
            _ = try await CloudAccountIdentityVerifier.verify(using: next.makeClient(
                backoff: backoff, containerIdentifier: "data"
            ))
            XCTFail("Cancellation must not discard the server's retry deadline")
        } catch let failure as CloudAccountVerificationFailure {
            XCTAssertEqual(failure.kind, .serviceUnavailable)
            XCTAssertEqual(failure.retryAfter, 60)
        }
        let calls = await next.calls
        XCTAssertTrue(calls.isEmpty)
    }

    @MainActor
    func testCancellingOverlappingRefreshRestoresSettledStatusInsteadOfSpinner() async {
        let firstStarted = expectation(description: "first refresh started")
        let secondStarted = expectation(description: "second refresh started")
        let firstGate = CloudVerificationGate(started: firstStarted)
        let secondGate = CloudVerificationGate(started: secondStarted)
        let script = CloudVerificationScript(
            firstStatusGate: firstGate, secondStatusGate: secondGate
        )
        let monitor = CloudSyncMonitor(client: script.client)
        let first = Task { await monitor.refresh() }
        await fulfillment(of: [firstStarted], timeout: 1)
        let second = Task { await monitor.refresh() }
        await fulfillment(of: [secondStarted], timeout: 1)
        second.cancel()
        await second.value
        XCTAssertEqual(monitor.availability, .unavailable)
        await firstGate.release()
        await secondGate.release()
        await first.value
        XCTAssertEqual(monitor.availability, .unavailable)
    }

    @MainActor
    func testMonitorIgnoresSupersededAndCancelledRefreshResults() async throws {
        let started = expectation(description: "old refresh started")
        let gate = CloudVerificationGate(started: started)
        let script = CloudVerificationScript(firstStatusGate: gate)
        let monitor = CloudSyncMonitor(client: script.client)
        let first = Task { await monitor.refresh() }
        await fulfillment(of: [started], timeout: 1)
        await monitor.refresh()
        XCTAssertEqual(monitor.availability, .available)
        await gate.release(status: .noAccount)
        await first.value
        XCTAssertEqual(monitor.availability, .available)
        XCTAssertNil(monitor.failure)

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await monitor.refresh()
        }
        await cancelled.value
        XCTAssertEqual(monitor.availability, .available)
    }
}

private final class CloudVerificationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 100
    private var firstRead: XCTestExpectation?

    init(firstRead: XCTestExpectation? = nil) {
        self.firstRead = firstRead
    }

    var now: TimeInterval {
        lock.lock()
        let firstRead = self.firstRead
        self.firstRead = nil
        let value = self.value
        lock.unlock()
        firstRead?.fulfill()
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value += interval
    }
}

private actor CloudVerificationGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<CKAccountStatus, Never>?
    private var releasedStatus: CKAccountStatus?

    init(started: XCTestExpectation) { self.started = started }

    func wait() async -> CKAccountStatus {
        started.fulfill()
        if let releasedStatus { return releasedStatus }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release(status: CKAccountStatus = .available) {
        releasedStatus = status
        continuation?.resume(returning: status)
        continuation = nil
    }
}

private actor CloudVerificationScript {
    let status: CKAccountStatus
    let recordName: String
    let changesIdentity: Bool
    let firstStatusGate: CloudVerificationGate?
    let secondStatusGate: CloudVerificationGate?
    var probeErrors: [CKError]
    private var identityCalls = 0
    private(set) var calls: [String] = []

    init(
        status: CKAccountStatus = .available,
        recordName: String = "test-account",
        changesIdentity: Bool = false,
        probeErrors: [CKError] = [],
        firstStatusGate: CloudVerificationGate? = nil,
        secondStatusGate: CloudVerificationGate? = nil
    ) {
        self.status = status
        self.recordName = recordName
        self.changesIdentity = changesIdentity
        self.probeErrors = probeErrors
        self.firstStatusGate = firstStatusGate
        self.secondStatusGate = secondStatusGate
    }

    nonisolated var client: CloudAccountVerificationClient {
        CloudAccountVerificationClient(
            accountStatus: { await self.accountStatus() },
            userRecordID: { await self.userRecordID() },
            probePrivateDatabase: { try await self.probe() }
        )
    }

    nonisolated func makeClient(
        backoff: CloudAccountVerificationBackoff,
        containerIdentifier: String
    ) -> CloudAccountVerificationClient {
        var result = client
        result.backoff = backoff
        result.containerIdentifier = containerIdentifier
        return result
    }

    private func accountStatus() async -> CKAccountStatus {
        let statusCalls = calls.filter { $0 == "status" }.count
        calls.append("status")
        if statusCalls == 0, let firstStatusGate { return await firstStatusGate.wait() }
        if statusCalls == 1, let secondStatusGate { return await secondStatusGate.wait() }
        return status
    }

    private func userRecordID() -> CKRecord.ID {
        calls.append("identity")
        identityCalls += 1
        return CKRecord.ID(recordName: changesIdentity && identityCalls > 1 ? "changed-account" : recordName)
    }

    private func probe() throws {
        calls.append("probe")
        if !probeErrors.isEmpty { throw probeErrors.removeFirst() }
    }
}
