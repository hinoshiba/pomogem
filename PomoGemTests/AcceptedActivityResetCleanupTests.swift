import XCTest
@testable import PomoGem

@MainActor
final class AcceptedActivityResetCleanupTests: XCTestCase {
    func testCommittedCleanupRunsWhenDeferredViewWorkIsCancelledBeforeItStarts() async throws {
        let started = expectation(description: "accepted cleanup started")
        let completed = expectation(description: "accepted cleanup completed")
        let gate = AcceptedResetCleanupGate(started: started)
        var owner: AcceptedResetLifetimeOwner? = AcceptedResetLifetimeOwner()
        weak var retainedOwner = owner
        let cleanup = AcceptedActivityResetCleanup.start(retaining: owner!) {
            await gate.wait()
            completed.fulfill()
        }
        owner = nil

        // This is the first-frame grace task that can be cancelled before its
        // first instruction. The committed cleanup is accepted independently.
        let scope = ViewTaskScope()
        var observerRan = false
        scope.start {
            observerRan = true
            _ = try? await cleanup.value
        }
        scope.cancelAll()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(observerRan)
        XCTAssertNotNil(retainedOwner, "A remount must wait for accepted external cleanup")
        gate.release()
        await fulfillment(of: [completed], timeout: 2)
        try await cleanup.value
        XCTAssertNil(retainedOwner, "The old store owner can retire after cleanup finishes")
    }

    func testLaterResetCleanupWaitsForEarlierAcceptedEffects() async throws {
        let firstStarted = expectation(description: "first cleanup started")
        let secondStarted = expectation(description: "second cleanup started")
        let gate = AcceptedResetCleanupGate(started: firstStarted)
        var order: [String] = []
        let owner = AcceptedResetLifetimeOwner()
        let first = AcceptedActivityResetCleanup.start(retaining: owner) {
            order.append("first-start")
            await gate.wait()
            order.append("first-end")
        }
        let second = AcceptedActivityResetCleanup.start(after: first, retaining: owner) {
            order.append("second")
            secondStarted.fulfill()
        }
        await fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertEqual(order, ["first-start"])
        gate.release()
        await fulfillment(of: [secondStarted], timeout: 2)
        try await second.value
        XCTAssertEqual(order, ["first-start", "first-end", "second"])
    }

    func testPendingReceiptSurvivesRestartAndClearsOnlyAfterRetryCompletes() async throws {
        let suite = "AcceptedActivityResetCleanupTests.\(UUID().uuidString)"
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { firstDefaults.removePersistentDomain(forName: suite) }
        let firstJournal = ActivityResetCleanupJournal(defaults: firstDefaults, key: "test-reset")
        let epochID = UUID()
        let initial = firstJournal.begin(epochID: epochID)
        firstDefaults.synchronize()

        // Drop all process-local task/receipt state and reconstruct only from
        // the persisted defaults domain, as a new Root does after termination.
        let restartedDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let restarted = ActivityResetCleanupJournal(defaults: restartedDefaults, key: "test-reset")
        XCTAssertEqual(restarted.pendingReceipt, initial.receipt)
        let retry = restarted.begin(epochID: epochID)
        XCTAssertNotEqual(retry.receipt, initial.receipt)
        let started = expectation(description: "retried cleanup started")
        let gate = AcceptedResetCleanupGate(started: started)
        let cleanup = AcceptedActivityResetCleanup.start(
            retaining: AcceptedResetLifetimeOwner(), completing: retry
        ) { await gate.wait() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(restarted.pendingReceipt, retry.receipt)
        gate.release()
        try await cleanup.value
        XCTAssertFalse(restarted.hasPendingCleanup)
    }

    func testFailedCleanupRetainsReceiptForNextLaunch() async throws {
        enum InjectedFailure: Error { case failed }
        let suite = "AcceptedActivityResetCleanupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = ActivityResetCleanupJournal(defaults: defaults, key: "test-reset")
        let ticket = journal.begin(epochID: UUID())
        let cleanup = AcceptedActivityResetCleanup.start(
            retaining: AcceptedResetLifetimeOwner(), completing: ticket
        ) { throw InjectedFailure.failed }
        do {
            try await cleanup.value
            XCTFail("A failed service must not acknowledge the cleanup")
        } catch InjectedFailure.failed { }
        XCTAssertEqual(journal.pendingReceipt, ticket.receipt)
    }

    func testCancelledCleanupCannotAcknowledgeReceiptAfterLateServiceReturn() async throws {
        let suite = "AcceptedActivityResetCleanupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = ActivityResetCleanupJournal(defaults: defaults, key: "test-reset")
        let ticket = journal.begin(epochID: UUID())
        let started = expectation(description: "cleanup service started")
        let gate = AcceptedResetCleanupGate(started: started)
        let cleanup = AcceptedActivityResetCleanup.start(
            retaining: AcceptedResetLifetimeOwner(), completing: ticket
        ) { await gate.wait() }
        await fulfillment(of: [started], timeout: 2)
        cleanup.cancel()
        gate.release()
        do {
            try await cleanup.value
            XCTFail("Cancelled cleanup cannot acknowledge durable completion")
        } catch is CancellationError { }
        XCTAssertEqual(journal.pendingReceipt, ticket.receipt)
    }

    func testOlderCompletionCannotClearNewerReceiptIncludingSameEpochRetry() async throws {
        let suite = "AcceptedActivityResetCleanupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = ActivityResetCleanupJournal(defaults: defaults, key: "test-reset")
        for repeatsEpoch in [false, true] {
            let initial = journal.begin(epochID: UUID())
            let started = expectation(description: "old cleanup started")
            let gate = AcceptedResetCleanupGate(started: started)
            let old = AcceptedActivityResetCleanup.start(
                retaining: AcceptedResetLifetimeOwner(), completing: initial
            ) { await gate.wait() }
            await fulfillment(of: [started], timeout: 2)
            let newest = journal.begin(
                epochID: repeatsEpoch ? initial.receipt.epochID : UUID()
            )
            gate.release()
            try await old.value
            XCTAssertEqual(journal.pendingReceipt, newest.receipt)
            let current = AcceptedActivityResetCleanup.start(
                retaining: AcceptedResetLifetimeOwner(), completing: newest
            ) { }
            try await current.value
            XCTAssertFalse(journal.hasPendingCleanup)
        }
    }

    func testReceiptCompletionRemainsBoundToAcceptedNamespace() async throws {
        let suite = "AcceptedActivityResetCleanupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstKey = AccountScopedLocalState.defaultsKey(
            base: ActivityResetCleanupJournal.defaultsBaseKey, namespace: AccountDataNamespace()
        )
        let secondKey = AccountScopedLocalState.defaultsKey(
            base: ActivityResetCleanupJournal.defaultsBaseKey, namespace: AccountDataNamespace()
        )
        let first = ActivityResetCleanupJournal(defaults: defaults, key: firstKey)
        let second = ActivityResetCleanupJournal(defaults: defaults, key: secondKey)
        let oldTicket = first.begin(epochID: UUID())
        let newTicket = second.begin(epochID: UUID())
        let cleanup = AcceptedActivityResetCleanup.start(
            retaining: AcceptedResetLifetimeOwner(), completing: oldTicket
        ) { }
        try await cleanup.value
        XCTAssertFalse(first.hasPendingCleanup)
        XCTAssertEqual(second.pendingReceipt, newTicket.receipt)
    }

    func testMalformedPendingReceiptStillRequestsRecovery() throws {
        let suite = "AcceptedActivityResetCleanupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = ActivityResetCleanupJournal(defaults: defaults, key: "test-reset")
        defaults.set(["epoch": "broken"], forKey: journal.key)
        XCTAssertTrue(journal.hasPendingCleanup)
        XCTAssertNil(journal.pendingReceipt)
        let repair = journal.begin(epochID: UUID())
        XCTAssertEqual(journal.pendingReceipt, repair.receipt)
    }

    func testLaterCleanupStillRunsAfterEarlierCleanupError() async throws {
        enum InjectedFailure: Error { case failed }
        let owner = AcceptedResetLifetimeOwner()
        let first = AcceptedActivityResetCleanup.start(retaining: owner) {
            throw InjectedFailure.failed
        }
        var laterRan = false
        let second = AcceptedActivityResetCleanup.start(after: first, retaining: owner) {
            laterRan = true
        }
        try await second.value
        XCTAssertTrue(laterRan)
    }
}

private final class AcceptedResetLifetimeOwner {}

@MainActor
private final class AcceptedResetCleanupGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        started.fulfill()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
