import CloudKit
import XCTest
@testable import PomoGem

/// Exercises the real pre-mirror asynchronous gate with injected read-only
/// dependencies. No ModelContainer, account resolver, or network is created.
@MainActor
final class CloudOfflineHistoryPreflightTests: XCTestCase {
    func testUnchangedEmptyHistoryRequiresBothAccountChecksAndACompletedRead() async throws {
        let state = OfflineHistoryTestState()
        let expected = binding()
        let client = client(markers: [], expected: expected, state: state)
        try await CloudActivityHistoryPreflight(client: client).verifyOfflineBaseline(nil,
            expectedBinding: expected, validateMount: { state.validationCount += 1 })
        XCTAssertEqual(state.events, ["account", "read", "account"])
        XCTAssertEqual(state.validationCount, 4)
        XCTAssertTrue(CloudActivityHistoryPreflight.sameOfflineHistory(nil, nil))
    }

    func testSameWinnerWithTransportedDatePrecisionAllowsReconnection() async throws {
        let baseline = marker()
        let transported = marker(date: baseline.resetAt.addingTimeInterval(0.0004))
        let older = marker(sequence: baseline.sequence - 1)
        let state = OfflineHistoryTestState()
        let expected = binding()
        try await CloudActivityHistoryPreflight(client: client(markers: [older, transported],
            expected: expected, state: state)).verifyOfflineBaseline(baseline,
                expectedBinding: expected, validateMount: {})
        XCTAssertEqual(state.events, ["account", "read", "account"])
        XCTAssertTrue(CloudActivityHistoryPreflight.sameOfflineHistory(baseline, transported))
        XCTAssertTrue(CloudActivityHistoryPreflight.sameOfflineHistory(transported, baseline))
    }

    func testNewerOlderMissingAndChangedIdentityHistoryRejectsBeforeMount() async {
        let baseline = marker()
        let cases: [(String, ActivityResetSnapshot?, [ActivityResetSnapshot])] = [
            ("newer", baseline, [marker(sequence: 10)]),
            ("older", baseline, [marker(sequence: 8)]),
            ("missing server", baseline, []),
            ("missing baseline", nil, [baseline]),
            ("different epoch", baseline, [marker(epoch: UUID())]),
            ("different marker", baseline, [marker(id: UUID())]),
            ("different writer", baseline, [marker(writer: "other-device")]),
            ("new winner among matching old history", baseline, [baseline, marker(sequence: 10)])
        ]
        for (name, local, remote) in cases {
            let state = OfflineHistoryTestState()
            let expected = binding()
            var mayMount = false
            do {
                try await CloudActivityHistoryPreflight(client: client(markers: remote,
                    expected: expected, state: state)).verifyOfflineBaseline(local,
                        expectedBinding: expected, validateMount: {})
                mayMount = true
                XCTFail("Changed history must reject: \(name)")
            } catch {
                XCTAssertEqual(error as? CloudActivityHistoryPreflightError, .offlineHistoryChanged, name)
            }
            XCTAssertFalse(mayMount, name)
            XCTAssertEqual(state.events, ["account", "read", "account"], name)
        }
    }

    func testUnsupportedBaselineCannotMatchEvenAnIdenticalMarker() async {
        let unsupported = marker(sequence: ActivityResetPolicy.maximumSupportedSequence + 1)
        XCTAssertFalse(CloudActivityHistoryPreflight.sameOfflineHistory(unsupported, unsupported))
        let state = OfflineHistoryTestState()
        let expected = binding()
        do {
            try await CloudActivityHistoryPreflight(client: client(markers: [unsupported],
                expected: expected, state: state)).verifyOfflineBaseline(unsupported,
                    expectedBinding: expected, validateMount: {})
            XCTFail("Unsupported local baseline cannot authorize a mirror")
        } catch { XCTAssertEqual(error as? CloudActivityHistoryPreflightError, .offlineHistoryChanged) }
    }

    func testAccountFailureBeforeReadOrAccountChangeAfterReadRejectsBeforeMount() async {
        for failingCheck in [1, 2] {
            let state = OfflineHistoryTestState()
            let expected = binding()
            let failure = CloudAccountVerificationFailure(
                kind: failingCheck == 1 ? .noAccount : .accountChanged,
                stage: failingCheck == 1 ? .accountStatus : .identityAfterProbe)
            let client = CloudActivityHistoryClient(verifyAccount: { supplied in
                XCTAssertEqual(supplied, expected)
                state.accountChecks += 1
                if state.accountChecks == failingCheck { throw failure }
            }, readMarkers: { await state.read([]) })
            do {
                try await CloudActivityHistoryPreflight(client: client).verifyOfflineBaseline(nil,
                    expectedBinding: expected, validateMount: {})
                XCTFail("Failed identity must reject before mirror construction")
            } catch { XCTAssertEqual(error as? CloudAccountVerificationFailure, failure) }
            XCTAssertEqual(state.accountChecks, failingCheck)
            XCTAssertEqual(state.readCount, failingCheck == 1 ? 0 : 1)
        }
    }

    func testFailedOrIncompleteReadCannotMasqueradeAsAnEmptyServerHistory() async {
        for failure in [CloudActivityHistoryPreflightError.incompleteHistory,
                        .malformedHistory, .unsupportedZone, .historyLimit] {
            let state = OfflineHistoryTestState()
            let client = CloudActivityHistoryClient(verifyAccount: { _ in state.accountChecks += 1 },
                readMarkers: { throw failure })
            do {
                try await CloudActivityHistoryPreflight(client: client).verifyOfflineBaseline(nil,
                    expectedBinding: binding(), validateMount: {})
                XCTFail("Read failure cannot authorize empty-history admission")
            } catch { XCTAssertEqual(error as? CloudActivityHistoryPreflightError, failure) }
            XCTAssertEqual(state.accountChecks, 1)
        }
    }

    func testStaleMountLeaseAfterEachSuspensionRejectsEvenMatchingHistory() async {
        for invalidationPoint in [1, 2, 3] {
            let state = OfflineHistoryTestState()
            let client = CloudActivityHistoryClient(verifyAccount: { _ in
                state.accountChecks += 1
                let point = state.accountChecks == 1 ? 1 : 3
                if point == invalidationPoint { state.active = false }
            }, readMarkers: {
                await state.invalidateDuringRead(invalidationPoint == 2)
                return []
            })
            do {
                try await CloudActivityHistoryPreflight(client: client).verifyOfflineBaseline(nil,
                    expectedBinding: binding(), validateMount: {
                        guard state.active else { throw OfflineHistoryTestError.staleMount }
                    })
                XCTFail("Stale launch must reject at boundary \(invalidationPoint)")
            } catch { XCTAssertEqual(error as? OfflineHistoryTestError, .staleMount) }
            XCTAssertEqual(state.accountChecks, invalidationPoint == 3 ? 2 : 1)
            XCTAssertEqual(state.readCount, invalidationPoint == 1 ? 0 : 1)
        }
    }

    func testCancellationDoesNotWaitForAccountOrReadAndIgnoresLateSuccess() async {
        await assertBoundedCompletion(cancel: true)
    }

    func testWholeDeadlineBoundsAccountOrReadThatIgnoresCancellation() async {
        await assertBoundedCompletion(cancel: false)
    }

    func testFreshLocalWinnerAllowsLegitimateImportAfterRecordedBaselineBecameOld() async throws {
        let remote = marker(sequence: 10)
        let state = OfflineHistoryTestState()
        let expected = binding()
        var localReads = 0
        try await CloudActivityHistoryPreflight(client: client(markers: [marker(), remote],
            expected: expected, state: state)).verifyExistingReplicaBeforeMirroring(
                recordedBaseline: .observed(marker()), expectedBinding: expected,
                readCurrentLocalMarker: {
                    localReads += 1
                    state.events.append("local")
                    return self.marker(sequence: 10, date: remote.resetAt.addingTimeInterval(0.0004))
                }, validateMount: {})
        XCTAssertEqual(localReads, 1)
        XCTAssertEqual(state.events, ["account", "read", "account", "local"])
    }

    func testUnchangedRecordedHistoryDoesNotOpenReaderOrRejectUnsentLocalReset() async throws {
        let currentServer = marker()
        XCTAssertTrue(CloudActivityHistoryAdmissionPolicy.permitsExistingReplica(
            recordedBaseline: .observed(currentServer), currentLocal: marker(sequence: 10), remote: currentServer))
        let state = OfflineHistoryTestState()
        let expected = binding()
        try await CloudActivityHistoryPreflight(client: client(markers: [currentServer],
            expected: expected, state: state)).verifyExistingReplicaBeforeMirroring(
                recordedBaseline: .observed(currentServer), expectedBinding: expected,
                readCurrentLocalMarker: { XCTFail("Matching recorded history needs no store reopen"); return nil },
                validateMount: {})
        XCTAssertEqual(state.events, ["account", "read", "account"])
    }

    func testLegacyReceiptAbsenceRequiresSuccessfulFreshLocalReadIncludingKnownEmpty() async throws {
        XCTAssertFalse(CloudActivityHistoryAdmissionPolicy.recordedBaselineMatches(.unavailable, remote: nil))
        XCTAssertTrue(CloudActivityHistoryAdmissionPolicy.recordedBaselineMatches(.observed(nil), remote: nil))
        for winner in [nil, marker()] {
            let state = OfflineHistoryTestState()
            let expected = binding()
            var localReads = 0
            try await CloudActivityHistoryPreflight(client: client(markers: winner.map { [$0] } ?? [],
                expected: expected, state: state)).verifyExistingReplicaBeforeMirroring(
                    recordedBaseline: .unavailable, expectedBinding: expected,
                    readCurrentLocalMarker: { localReads += 1; return winner }, validateMount: {})
            XCTAssertEqual(localReads, 1)
            XCTAssertEqual(state.events, ["account", "read", "account"])
        }
    }

    func testNoMatchingProofRejectsNewerLocalOlderLocalAndEveryOrderIdentityDifference() async {
        let remote = marker(sequence: 10)
        let localCases: [ActivityResetSnapshot?] = [nil, marker(), marker(sequence: 11),
            marker(sequence: 10, id: UUID()), marker(sequence: 10, epoch: UUID()),
            marker(sequence: 10, writer: "different-writer")]
        for local in localCases {
            XCTAssertFalse(CloudActivityHistoryAdmissionPolicy.permitsExistingReplica(
                recordedBaseline: .observed(marker()), currentLocal: local, remote: remote))
            let state = OfflineHistoryTestState()
            let expected = binding()
            var mayConstructMirror = false
            do {
                try await CloudActivityHistoryPreflight(client: client(markers: [remote],
                    expected: expected, state: state)).verifyExistingReplicaBeforeMirroring(
                        recordedBaseline: .observed(marker()), expectedBinding: expected,
                        readCurrentLocalMarker: { local }, validateMount: {})
                mayConstructMirror = true
            } catch { XCTAssertEqual(error as? CloudActivityHistoryPreflightError, .offlineHistoryChanged) }
            XCTAssertFalse(mayConstructMirror)
        }
    }

    func testMissingOrRevocationOnlyReceiptCannotInventKnownEmptyHistory() {
        let binding = binding()
        XCTAssertEqual(CloudActivityHistoryRecordedBaseline(receipt: nil), .unavailable)
        let revoked = CloudOfflineAccessReceipt(revisionID: UUID(), binding: binding,
            origin: .revokedWithoutBaseline, isDatasetGenerationKnown: false,
            datasetGenerationID: nil, resetBaseline: nil, wasUsedOffline: false, revocation: .accountChanged)
        XCTAssertEqual(CloudActivityHistoryRecordedBaseline(receipt: revoked), .unavailable)
        for origin in [CloudOfflineAccessOrigin.verifiedOnline, .legacySuccessfulMount] {
            let receipt = CloudOfflineAccessReceipt(revisionID: UUID(), binding: binding,
                origin: origin, isDatasetGenerationKnown: true, datasetGenerationID: nil,
                resetBaseline: nil, wasUsedOffline: origin == .legacySuccessfulMount, revocation: nil)
            XCTAssertEqual(CloudActivityHistoryRecordedBaseline(receipt: receipt), .observed(nil))
        }
    }

    func testFreshLocalReadFailureCannotBeTreatedAsMatchingEmptyServer() async {
        let state = OfflineHistoryTestState()
        let expected = binding()
        do {
            try await CloudActivityHistoryPreflight(client: client(markers: [], expected: expected, state: state))
                .verifyExistingReplicaBeforeMirroring(recordedBaseline: .unavailable, expectedBinding: expected,
                    readCurrentLocalMarker: {
                        throw NSError(domain: "private-synthetic-local-error", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "UNSAFE_LOCAL_DETAIL"])
                    }, validateMount: {})
            XCTFail("Failed local fetch is not a known-empty cache")
        } catch {
            XCTAssertEqual(error as? CloudActivityHistoryPreflightError, .localHistoryUnavailable)
            XCTAssertFalse(error.localizedDescription.contains("UNSAFE_LOCAL_DETAIL"))
        }
    }

    func testInvalidationDuringReadOnlyContainerOpenRejectsMatchingLocalResult() async {
        let state = OfflineHistoryTestState()
        let expected = binding()
        do {
            try await CloudActivityHistoryPreflight(client: client(markers: [], expected: expected, state: state))
                .verifyExistingReplicaBeforeMirroring(recordedBaseline: .unavailable, expectedBinding: expected,
                    readCurrentLocalMarker: { state.active = false; return nil }, validateMount: {
                        guard state.active else { throw OfflineHistoryTestError.staleMount }
                    })
            XCTFail("A matching local observation cannot outlive its source lease")
        } catch { XCTAssertEqual(error as? OfflineHistoryTestError, .staleMount) }
    }

    func testAccountOrRemoteFailureCannotReachTheReadOnlyLocalFallback() async {
        for failAccount in [true, false] {
            let client = CloudActivityHistoryClient(verifyAccount: { _ in
                if failAccount { throw AppleAccountBoundaryResolutionError.blocked(.accountMismatch) }
            }, readMarkers: { throw CloudActivityHistoryPreflightError.incompleteHistory })
            var localReads = 0
            do {
                try await CloudActivityHistoryPreflight(client: client)
                    .verifyExistingReplicaBeforeMirroring(recordedBaseline: .unavailable, expectedBinding: binding(),
                        readCurrentLocalMarker: { localReads += 1; return nil }, validateMount: {})
                XCTFail("Incomplete account/server proof cannot fall back to local observations")
            } catch {
                if failAccount { XCTAssertEqual(error as? AppleAccountBoundaryResolutionError, .blocked(.accountMismatch)) }
                else { XCTAssertEqual(error as? CloudActivityHistoryPreflightError, .incompleteHistory) }
            }
            XCTAssertEqual(localReads, 0)
        }
    }

    private func assertBoundedCompletion(cancel: Bool) async {
        // Includes the final account recheck, when both the baseline and the
        // fetched server winner are already known to match.
        for pausedPoint in [1, 2, 3] {
            let started = expectation(description: "paused dependency \(pausedPoint)")
            let returned = expectation(description: "bounded return \(pausedPoint)")
            let lateReturned = expectation(description: "late dependency \(pausedPoint)")
            let gate = OfflineHistoryReadGate(started: started, lateReturned: lateReturned)
            let state = OfflineHistoryTestState()
            let expected = binding()
            let client = CloudActivityHistoryClient(verifyAccount: { _ in
                state.accountChecks += 1
                if (state.accountChecks == 1 ? 1 : 3) == pausedPoint { await gate.wait() }
            }, readMarkers: {
                if pausedPoint == 2 { await gate.wait() }
                return []
            })
            let task = Task { @MainActor in
                defer { returned.fulfill() }
                do {
                    try await CloudActivityHistoryPreflight(client: client, timeout: cancel ? 10 : 0.15)
                        .verifyOfflineBaseline(nil, expectedBinding: expected, validateMount: {})
                    state.allowed = true
                    XCTFail("Abandoned read cannot authorize a mirror")
                } catch {
                    if cancel { XCTAssertTrue(error is CancellationError) }
                    else { XCTAssertEqual(error as? CloudActivityHistoryPreflightError, .timedOut) }
                }
            }
            await fulfillment(of: [started], timeout: 2)
            if cancel { task.cancel() }
            await fulfillment(of: [returned], timeout: 2)
            XCTAssertFalse(state.allowed)
            let accountChecksAtReturn = state.accountChecks
            await gate.release()
            await fulfillment(of: [lateReturned], timeout: 2)
            await task.value
            XCTAssertFalse(state.allowed)
            XCTAssertEqual(state.accountChecks, accountChecksAtReturn,
                "Late successful reads cannot resume subsequent account work")
        }
    }

    private func client(markers: [ActivityResetSnapshot], expected: ActiveAccountLocalBinding,
                        state: OfflineHistoryTestState) -> CloudActivityHistoryClient {
        CloudActivityHistoryClient(verifyAccount: { supplied in
            XCTAssertEqual(supplied, expected)
            state.events.append("account")
        }, readMarkers: { await state.read(markers) })
    }

    private func marker(sequence: Int = 9,
                        id: UUID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
                        epoch: UUID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!,
                        writer: String = "offline-test-device",
                        date: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> ActivityResetSnapshot {
        ActivityResetSnapshot(id: id, epochID: epoch, sequence: sequence, resetAt: date, writerDeviceID: writer)
    }

    private func binding() -> ActiveAccountLocalBinding {
        ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: String(repeating: "a", count: 64))!
    }
}

@MainActor
private final class OfflineHistoryTestState {
    var events: [String] = []
    var accountChecks = 0
    var readCount = 0
    var validationCount = 0
    var active = true
    var allowed = false
    func read(_ markers: [ActivityResetSnapshot]) -> [ActivityResetSnapshot] {
        events.append("read")
        readCount += 1
        return markers
    }
    func invalidateDuringRead(_ invalidate: Bool) {
        readCount += 1
        if invalidate { active = false }
    }
}

private enum OfflineHistoryTestError: Error, Equatable { case staleMount }

private actor OfflineHistoryReadGate {
    let started: XCTestExpectation
    let lateReturned: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    init(started: XCTestExpectation, lateReturned: XCTestExpectation) {
        self.started = started
        self.lateReturned = lateReturned
    }
    func wait() async {
        if !released {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        lateReturned.fulfill()
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
