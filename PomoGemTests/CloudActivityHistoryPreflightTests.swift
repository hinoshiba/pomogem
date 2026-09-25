import CloudKit
import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class CloudActivityHistoryPreflightTests: XCTestCase {
    func testParserUsesDocumentedMarkerFieldsAndIgnoresOtherEntities() throws {
        let expected = marker(sequence: 9)
        XCTAssertEqual(try CloudActivityHistoryRecordParser.parse(record(expected)), expected)
        let unrelated = CKRecord(recordType: "CD_StudySession")
        unrelated["CD_entityName"] = "StudySession" as CKRecordValue
        XCTAssertNil(try CloudActivityHistoryRecordParser.parse(unrelated))
    }

    func testMalformedMarkerCannotBeMistakenForEmptyHistory() {
        for key in CloudActivityHistoryRecordParser.desiredKeys {
            let malformed = record(marker(sequence: 9))
            malformed[key] = nil
            XCTAssertThrowsError(try CloudActivityHistoryRecordParser.parse(malformed), key) { error in
                XCTAssertEqual(error as? CloudActivityHistoryPreflightError, .malformedHistory)
            }
        }
        for invalid in [NSNumber(value: true), NSNumber(value: 1.5), NSNumber(value: Double.nan)] {
            let malformed = record(marker(sequence: 9))
            malformed["CD_sequence"] = invalid
            XCTAssertThrowsError(try CloudActivityHistoryRecordParser.parse(malformed))
        }
    }

    func testUnsupportedOrdinalMatchesLocalWinnerPolicy() throws {
        for ordinal in [-1, ActivityResetPolicy.maximumSupportedSequence + 1] {
            let unsupported = record(marker(sequence: 9))
            unsupported["CD_sequence"] = NSNumber(value: ordinal)
            XCTAssertNil(try CloudActivityHistoryRecordParser.parse(unsupported))
        }
    }

    func testAccumulatorRequiresEveryPageAndAppliesMarkerDeletions() throws {
        var accumulator = CloudActivityHistoryAccumulator()
        let older = record(marker(sequence: 2))
        let newer = record(marker(sequence: 9))
        accumulator.record(older.recordID, result: .success(older))
        accumulator.page(.success(true))
        XCTAssertThrowsError(try accumulator.result(operation: .success(()))) { error in
            XCTAssertEqual(error as? CloudActivityHistoryPreflightError, .incompleteHistory)
        }
        accumulator.record(newer.recordID, result: .success(newer))
        accumulator.deleted(newer.recordID)
        accumulator.page(.success(false))
        let snapshots = try accumulator.result(operation: .success(()))
        XCTAssertEqual(snapshots.map(\.sequence), [2])
        XCTAssertEqual(ActivityResetPolicy.currentMarker(from: snapshots)?.sequence, 2)
    }

    func testEmptyHistoryRequiresACompletedSuccessfulZone() throws {
        var accumulator = CloudActivityHistoryAccumulator()
        XCTAssertThrowsError(try accumulator.result(operation: .success(())))
        accumulator.page(.success(false))
        XCTAssertTrue(try accumulator.result(operation: .success(())).isEmpty)
    }

    /// launch-06. The restore screen's evidence comes from the traversal the
    /// preflight already makes; bookkeeping rows are not a previous jar.
    func testAccumulatorNoticesUserRowsButNotBookkeeping() throws {
        var bookkeeping = CloudActivityHistoryAccumulator()
        let kept = record(marker(sequence: 2))
        bookkeeping.record(kept.recordID, result: .success(kept))
        // Prefs included: every launch creates this device's settings row
        // before onboarding, so a new user's own row is not an earlier jar.
        for type in ["CD_FocusTimerDeviceClaim", "CD_SyncedFocusTimer", "CD_Prefs", "CD_Unknown"] {
            let row = CKRecord(recordType: type)
            row["CD_entityName"] = String(type.dropFirst(3)) as CKRecordValue
            bookkeeping.record(row.recordID, result: .success(row))
        }
        bookkeeping.page(.success(false))
        let quiet = try bookkeeping.observation(operation: .success(()))
        XCTAssertFalse(quiet.holdsUserRecords)
        XCTAssertEqual(quiet.markers.map(\.sequence), [2])

        for type in ["CD_Subject", "CD_StudySession", "CD_AchievementStone"] {
            var accumulator = CloudActivityHistoryAccumulator()
            let row = CKRecord(recordType: type)
            row["CD_entityName"] = String(type.dropFirst(3)) as CKRecordValue
            accumulator.record(row.recordID, result: .success(row))
            accumulator.page(.success(true))
            // An unfinished zone is evidence of nothing, user rows included.
            XCTAssertThrowsError(try accumulator.observation(operation: .success(())), type)
            accumulator.page(.success(false))
            let observed = try accumulator.observation(operation: .success(()))
            XCTAssertTrue(observed.holdsUserRecords, type)
            XCTAssertTrue(observed.markers.isEmpty, type)
        }
    }

    func testRunReportsWhetherTheServerHoldsUserRecords() async throws {
        for holds in [false, true] {
            let client = CloudActivityHistoryClient(verifyAccount: { _ in }, readHistory: {
                CloudActivityHistoryObservation(markers: [], holdsUserRecords: holds)
            })
            let observed = try await CloudActivityHistoryPreflight(client: client, timeout: 1)
                .run(expectedBinding: binding(), validateMount: {}, localMarker: { nil })
            XCTAssertEqual(observed.holdsUserRecords, holds)
        }
        let markerOnly = CloudActivityHistoryClient(verifyAccount: { _ in }, readMarkers: { [] })
        let observed = try await CloudActivityHistoryPreflight(client: markerOnly, timeout: 1)
            .run(expectedBinding: binding(), validateMount: {}, localMarker: { nil })
        XCTAssertFalse(observed.holdsUserRecords)
    }

    func testPerRecordPerZoneAndOperationErrorsNeverReturnPartialHistory() {
        for errorLocation in 0..<3 {
            var accumulator = CloudActivityHistoryAccumulator()
            let valid = record(marker(sequence: 9))
            accumulator.record(valid.recordID, result: .success(valid))
            let error = CKError(.networkFailure, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_DIAGNOSTIC_MUST_NOT_ESCAPE"])
            if errorLocation == 0 { accumulator.record(CKRecord.ID(recordName: "test-failure"), result: .failure(error)) }
            if errorLocation == 1 { accumulator.page(.failure(error)) }
            accumulator.page(.success(false))
            XCTAssertThrowsError(try accumulator.result(operation: errorLocation == 2 ? .failure(error) : .success(()))) { failure in
                guard let typedFailure = failure as? CloudActivityHistoryPreflightError,
                      case let .cloud(typed) = typedFailure else {
                    return XCTFail("Expected sanitized cloud failure")
                }
                XCTAssertEqual(typed.cloudKitCode, CKError.networkFailure.rawValue)
                XCTAssertFalse(failure.localizedDescription.contains("PRIVATE_DIAGNOSTIC_MUST_NOT_ESCAPE"))
            }
        }
    }

    func testAdmissionRequiresFullMarkerOrderAndNeverAdmitsMissingLocalHistory() {
        let remote = marker(sequence: 9, writer: "device-b")
        XCTAssertTrue(CloudActivityHistoryAdmissionPolicy.isReady(local: nil, remote: nil))
        XCTAssertFalse(CloudActivityHistoryAdmissionPolicy.isReady(local: nil, remote: remote))
        XCTAssertFalse(CloudActivityHistoryAdmissionPolicy.isReady(local: marker(sequence: 8), remote: remote))
        XCTAssertFalse(CloudActivityHistoryAdmissionPolicy.isReady(local: marker(sequence: 9, writer: "device-a"), remote: remote))
        XCTAssertTrue(CloudActivityHistoryAdmissionPolicy.isReady(local: remote, remote: remote))
        XCTAssertTrue(CloudActivityHistoryAdmissionPolicy.isReady(local: marker(sequence: 9, writer: "device-c"), remote: remote))
        XCTAssertTrue(CloudActivityHistoryAdmissionPolicy.isReady(local: marker(sequence: 10), remote: remote))
        let lowerEpoch = marker(sequence: 9, writer: "device-b", epochTail: "000000000001")
        let higherEpoch = marker(sequence: 9, writer: "device-b", epochTail: "000000000002")
        XCTAssertFalse(CloudActivityHistoryAdmissionPolicy.isReady(local: lowerEpoch, remote: higherEpoch))
        XCTAssertTrue(CloudActivityHistoryAdmissionPolicy.isReady(local: higherEpoch, remote: lowerEpoch))
        let higherID = ActivityResetSnapshot(id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!, epochID: remote.epochID, sequence: remote.sequence, resetAt: remote.resetAt, writerDeviceID: remote.writerDeviceID)
        XCTAssertFalse(CloudActivityHistoryAdmissionPolicy.isReady(local: remote, remote: higherID))
        XCTAssertTrue(CloudActivityHistoryAdmissionPolicy.isReady(local: higherID, remote: remote))
        let differentDate = ActivityResetSnapshot(id: remote.id, epochID: remote.epochID,
                                                  sequence: remote.sequence,
                                                  resetAt: remote.resetAt.addingTimeInterval(0.0001),
                                                  writerDeviceID: remote.writerDeviceID)
        XCTAssertTrue(CloudActivityHistoryAdmissionPolicy.isReady(local: differentDate, remote: remote))
        XCTAssertTrue(CloudActivityHistoryAdmissionPolicy.isReady(local: remote, remote: differentDate))
    }

    func testRunWaitsForImportThenAdmitsMatchingHistory() async throws {
        let server = marker(sequence: 9)
        let state = PreflightTestState()
        let firstPoll = expectation(description: "local history polled")
        let finished = expectation(description: "preflight finished")
        let client = CloudActivityHistoryClient(verifyAccount: { _ in state.accountChecks += 1 }, readMarkers: { [server] })
        let preflight = CloudActivityHistoryPreflight(client: client, timeout: 1, pollInterval: 0.01)
        let task = Task { @MainActor in
            defer { state.finished = true; finished.fulfill() }
            try await preflight.run(expectedBinding: binding(), validateMount: { state.mountChecks += 1 }) {
                if !state.didPoll { state.didPoll = true; firstPoll.fulfill() }
                return state.local
            }
        }
        await fulfillment(of: [firstPoll], timeout: 1)
        XCTAssertFalse(state.finished)
        state.local = server
        await fulfillment(of: [finished], timeout: 2)
        try await task.value
        XCTAssertEqual(state.accountChecks, 2)
        XCTAssertGreaterThanOrEqual(state.mountChecks, 5)
    }

    func testMountInvalidationAfterServerReadPreventsAdmission() async {
        let state = PreflightTestState()
        let client = CloudActivityHistoryClient(verifyAccount: { _ in state.accountChecks += 1 }, readMarkers: { [] })
        let preflight = CloudActivityHistoryPreflight(client: client, timeout: 1)
        do {
            try await preflight.run(expectedBinding: binding(), validateMount: {
                state.mountChecks += 1
                if state.mountChecks == 3 { throw PreflightTestError.invalidated }
            }, localMarker: {
                XCTFail("An invalid candidate cannot reach activity admission")
                return nil
            })
            XCTFail("An invalid candidate must fail")
        } catch { XCTAssertEqual(error as? PreflightTestError, .invalidated) }
    }

    func testMissingLocalMarkerTimesOutWithoutAdmission() async {
        let server = marker(sequence: 9)
        let client = CloudActivityHistoryClient(verifyAccount: { _ in }, readMarkers: { [server] })
        do {
            try await CloudActivityHistoryPreflight(client: client, timeout: 0.05, pollInterval: 0.01)
                .run(expectedBinding: binding(), validateMount: {}, localMarker: { nil })
            XCTFail("Missing imported history must not authorize writes")
        } catch { XCTAssertEqual(error as? CloudActivityHistoryPreflightError, .timedOut) }
    }

    func testMountInvalidationDuringFinalLocalReadPreventsAdmission() async {
        let server = marker(sequence: 9)
        let state = PreflightTestState()
        let client = CloudActivityHistoryClient(verifyAccount: { _ in }, readMarkers: { [server] })
        do {
            try await CloudActivityHistoryPreflight(client: client, timeout: 1)
                .run(expectedBinding: binding(), validateMount: {
                    if state.didPoll { throw PreflightTestError.invalidated }
                }, localMarker: {
                    state.didPoll = true
                    return server
                })
            XCTFail("A matching local marker cannot bypass the final mount check")
        } catch { XCTAssertEqual(error as? PreflightTestError, .invalidated) }
    }

    func testDeadlineAndCancellationDoNotWaitForUncooperativeRead() async {
        for cancel in [false, true] {
            let gate = PreflightReadGate()
            let started = expectation(description: "read started")
            let finished = expectation(description: "bounded completion")
            let state = PreflightTestState()
            let client = CloudActivityHistoryClient(verifyAccount: { _ in }, readMarkers: {
                started.fulfill()
                return await gate.wait()
            })
            let task = Task { @MainActor in
                defer { state.finished = true; finished.fulfill() }
                do {
                    try await CloudActivityHistoryPreflight(client: client, timeout: cancel ? 10 : 0.2)
                        .run(expectedBinding: binding(), validateMount: {}, localMarker: { nil })
                    XCTFail("A cancelled or timed-out read cannot authorize admission")
                } catch {
                    if cancel { XCTAssertTrue(error is CancellationError) }
                    else { XCTAssertEqual(error as? CloudActivityHistoryPreflightError, .timedOut) }
                }
            }
            await fulfillment(of: [started], timeout: 1)
            if cancel { task.cancel() }
            await fulfillment(of: [finished], timeout: 1)
            let completedBeforeRelease = state.finished
            await gate.release()
            await task.value
            XCTAssertTrue(completedBeforeRelease)
        }
    }

    private func marker(sequence: Int, writer: String = "device-b", epochTail: String = "000000000009") -> ActivityResetSnapshot {
        ActivityResetSnapshot(id: UUID(uuidString: "10000000-0000-0000-0000-000000000009")!, epochID: UUID(uuidString: "20000000-0000-0000-0000-\(epochTail)")!, sequence: sequence, resetAt: Date(timeIntervalSince1970: 1_700_000_000), writerDeviceID: writer)
    }

    private func record(_ marker: ActivityResetSnapshot) -> CKRecord {
        let record = CKRecord(recordType: "CD_ActivityResetMarker")
        record["CD_entityName"] = "ActivityResetMarker" as CKRecordValue
        record["CD_id"] = marker.id.uuidString as CKRecordValue
        record["CD_epochID"] = marker.epochID.uuidString as CKRecordValue
        record["CD_sequence"] = NSNumber(value: marker.sequence)
        record["CD_resetAt"] = marker.resetAt as CKRecordValue
        record["CD_writerDeviceID"] = marker.writerDeviceID as CKRecordValue
        return record
    }

    private func binding() -> ActiveAccountLocalBinding {
        ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: String(repeating: "a", count: 64))!
    }
}

@MainActor
private final class PreflightTestState {
    var accountChecks = 0
    var mountChecks = 0
    var didPoll = false
    var finished = false
    var local: ActivityResetSnapshot?
}

private enum PreflightTestError: Error, Equatable { case invalidated }

private actor PreflightReadGate {
    private var continuation: CheckedContinuation<[ActivityResetSnapshot], Never>?
    private var released = false
    func wait() async -> [ActivityResetSnapshot] {
        if released { return [] }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(returning: [])
        continuation = nil
    }
}
