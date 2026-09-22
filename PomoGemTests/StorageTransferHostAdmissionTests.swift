import Foundation
import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferHostAdmissionTests: XCTestCase {
    private enum Failure: Error { case malformedJournal, expiredAccess, resumeFailed }

    func testOrdinaryLocalLaunchDoesNotRequestCloudRecoveryWithoutJournal() async throws {
        var effects: [String] = []
        let resumed = try await StorageTransferHostJournalGate.resumeIfPending(
            readPending: { effects.append("local-journal"); return false },
            requireReleased: { XCTFail("No transfer exists") },
            validateAccess: { XCTFail("Local-only launch must not require an online account") },
            resume: { XCTFail("No transfer exists") }
        )
        XCTAssertFalse(resumed)
        XCTAssertEqual(effects, ["local-journal"])
    }

    func testMalformedJournalCannotFallThroughToOrdinaryMount() async {
        var mounted = false
        do {
            _ = try await StorageTransferHostJournalGate.resumeIfPending(
                readPending: { throw Failure.malformedJournal },
                requireReleased: { XCTFail("Malformed state has no authority") },
                validateAccess: { XCTFail("Malformed state has no authority") },
                resume: { XCTFail("Malformed state has no authority") }
            )
            mounted = true
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertFalse(mounted)
    }

    func testPendingTransferWaitsForEveryRetainedContainerBeforeResuming() async {
        final class Container { }
        let lifetimes = PersistenceContainerLifetimeTracker<Container>()
        let container = Container()
        lifetimes.track(container)
        var resumeCalls = 0
        do {
            _ = try await StorageTransferHostJournalGate.resumeIfPending(
                readPending: { true }, requireReleased: { try lifetimes.requireAllReleased() },
                validateAccess: { }, resume: { resumeCalls += 1 }
            )
            XCTFail("A retained source is still able to write")
        } catch {
            XCTAssertEqual(error as? PersistenceContainerRetirementError, .previousContainerStillActive)
        }
        withExtendedLifetime(container) { XCTAssertEqual(resumeCalls, 0) }
    }

    func testFailedResumeKeepsOrdinaryConstructorUnreachable() async {
        var mounted = false
        do {
            _ = try await StorageTransferHostJournalGate.resumeIfPending(
                readPending: { true }, requireReleased: { }, validateAccess: { },
                resume: { throw Failure.resumeFailed }
            )
            mounted = true
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertFalse(mounted)
    }

    func testGenerationRevocationAfterResumeDoesNotAuthorizeAnotherMount() async {
        var pending = true
        var valid = true
        var mounted = false
        do {
            _ = try await StorageTransferHostJournalGate.resumeIfPending(
                readPending: { pending }, requireReleased: { },
                validateAccess: { if !valid { throw Failure.expiredAccess } },
                resume: { await Task.yield(); pending = false; valid = false }
            )
            mounted = true
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertFalse(mounted)
    }

    func testResumeMustReleaseItsOwnCandidateAndClearDurableJournal() async throws {
        final class Container { }
        let lifetimes = PersistenceContainerLifetimeTracker<Container>()
        var candidate: Container?
        var pending = true
        do {
            _ = try await StorageTransferHostJournalGate.resumeIfPending(
                readPending: { pending }, requireReleased: { try lifetimes.requireAllReleased() },
                validateAccess: { }, resume: {
                    candidate = Container(); lifetimes.track(candidate!); pending = false
                }
            )
            XCTFail("The staged container has not retired")
        } catch {
            XCTAssertEqual(error as? PersistenceContainerRetirementError, .previousContainerStillActive)
        }
        candidate = nil
        pending = true
        do {
            _ = try await StorageTransferHostJournalGate.resumeIfPending(
                readPending: { pending }, requireReleased: { try lifetimes.requireAllReleased() },
                validateAccess: { }, resume: { }
            )
            XCTFail("Returning from an effect is not a durable commit")
        } catch { XCTAssertEqual(error as? StorageTransferError, .staleTransaction) }
        let resumed = try await StorageTransferHostJournalGate.resumeIfPending(
            readPending: { pending }, requireReleased: { try lifetimes.requireAllReleased() },
            validateAccess: { }, resume: { pending = false }
        )
        XCTAssertTrue(resumed)
    }

    func testCancelledLateResumeCannotAuthorizeMountEvenIfJournalWasCleared() async throws {
        var pending = true
        var held: CheckedContinuation<Void, Never>?
        let task = Task {
            try await StorageTransferHostJournalGate.resumeIfPending(
                readPending: { pending }, requireReleased: { }, validateAccess: { },
                resume: {
                    await withCheckedContinuation { held = $0 }
                    pending = false
                }
            )
        }
        for _ in 0..<100 where held == nil { try await Task.sleep(for: .milliseconds(1)) }
        let continuation = try XCTUnwrap(held)
        task.cancel()
        continuation.resume()
        do { _ = try await task.value; XCTFail("Cancelled launch cannot publish") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testProcessCloudMirrorHistorySurvivesContainerRetirementAndRepeatedMarks() throws {
        final class Container { }
        let history = StorageTransferProcessMountHistory()
        let lifetimes = PersistenceContainerLifetimeTracker<Container>()
        XCTAssertFalse(history.cloudMirrorWasOpened)
        // Mark before construction, including a constructor that could throw.
        history.markCloudMirrorOpened()
        var container: Container? = Container()
        lifetimes.track(container!)
        container = nil
        try lifetimes.requireAllReleased()
        XCTAssertTrue(history.cloudMirrorWasOpened)
        history.markCloudMirrorOpened()
        XCTAssertTrue(history.cloudMirrorWasOpened)
    }
}
