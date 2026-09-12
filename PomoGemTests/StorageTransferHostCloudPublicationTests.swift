import Foundation
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferHostCloudPublicationTests: XCTestCase {
    private enum Authority: Equatable { case unchanged, pending, newGeneration }
    private enum Failure: Error { case expiredMount }

    func testRemoteChangeDuringHistoryCannotPublishPreviouslyAdmittedCandidate() async throws {
        for changed in [Authority.pending, .newGeneration] {
            var authority = Authority.unchanged
            var published = false
            var finalReads = 0
            // Construction was allowed under the earlier server observation.
            let wasAdmittedBeforeHistory = authority == .unchanged
            XCTAssertTrue(wasAdmittedBeforeHistory)
            do {
                _ = try await StorageTransferHostCloudPublicationGate.verify(
                    prepareCandidate: {
                        await Task.yield()
                        authority = changed
                        return UUID()
                    },
                    verifyLatestDataset: {
                        finalReads += 1
                        switch authority {
                        case .unchanged: break
                        case .pending: throw StorageTransferRuntimeError.remoteRecoveryRequired
                        case .newGeneration: throw StorageTransferRuntimeError.datasetRefreshRequired
                        }
                    },
                    validateMount: {}
                )
                published = true
            } catch {
                XCTAssertEqual(error as? StorageTransferRuntimeError,
                    changed == .pending ? .remoteRecoveryRequired : .datasetRefreshRequired)
            }
            XCTAssertEqual(finalReads, 1)
            XCTAssertFalse(published)
        }
    }

    func testUnchangedDatasetReturnsCandidateAfterItsHistoryAndFinalRead() async throws {
        let candidate = UUID()
        var historyReady = false
        var datasetVerified = false
        let result = try await StorageTransferHostCloudPublicationGate.verify(
            prepareCandidate: {
                await Task.yield()
                historyReady = true
                return candidate
            },
            verifyLatestDataset: {
                XCTAssertTrue(historyReady)
                await Task.yield()
                datasetVerified = true
            },
            validateMount: {}
        )
        XCTAssertEqual(result, candidate)
        XCTAssertTrue(datasetVerified)
    }

    func testMountRevokedDuringFinalReadCannotPublishEvenIfDatasetMatches() async {
        var accessIsValid = true
        var published = false
        do {
            _ = try await StorageTransferHostCloudPublicationGate.verify(
                prepareCandidate: { UUID() },
                verifyLatestDataset: {
                    await Task.yield()
                    accessIsValid = false
                },
                validateMount: {
                    guard accessIsValid else { throw Failure.expiredMount }
                }
            )
            published = true
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertFalse(published)
    }

    func testCancelledFinalReadCannotPublishItsLateSuccess() async {
        let entered = expectation(description: "Final read entered")
        let completed = expectation(description: "Candidate rejected")
        let gate = PublicationReadGate()
        var published = false
        let task = Task { @MainActor in
            defer { completed.fulfill() }
            do {
                _ = try await StorageTransferHostCloudPublicationGate.verify(
                    prepareCandidate: { UUID() },
                    verifyLatestDataset: {
                        entered.fulfill()
                        await gate.wait()
                    },
                    validateMount: {}
                )
                published = true
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await gate.release()
        await fulfillment(of: [completed], timeout: 2)
        await task.value
        XCTAssertFalse(published)
    }
}

private actor PublicationReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
