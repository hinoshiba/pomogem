import XCTest
@testable import PomoGem

@MainActor
final class CloudLaunchDeadlineTests: XCTestCase {
    func testAbsoluteBudgetIncludesTimeBetweenSuccessfulRequests() async throws {
        let clock = LaunchDeadlineTestClock()
        var events: [String] = []
        let lease = CloudLaunchDeadline(timeout: 12,
            invalidateAttempt: { events.append("invalidated") },
            onExpiry: { events.append("terminal") }, now: { clock.value })
        clock.value = 5
        let first = try await lease.run { 1 }
        XCTAssertEqual(first, 1)
        clock.value = 11
        let second = try await lease.run { 2 }
        XCTAssertEqual(second, 2)
        clock.value = 12
        XCTAssertThrowsError(try lease.check()) {
            XCTAssertEqual($0 as? CloudLaunchDeadlineError, .expired)
        }
        XCTAssertEqual(events, ["invalidated", "terminal"])
        XCTAssertThrowsError(try lease.check())
        lease.cancel()
        XCTAssertEqual(events, ["invalidated", "terminal"])
    }

    func testWatchdogInvalidatesBeforeTerminalUIWithoutAnAwaitedRequest() async {
        let expired = expectation(description: "watchdog fired")
        var attempt = 4
        var expiryCount = 0
        let lease = CloudLaunchDeadline(timeout: 0.03,
            invalidateAttempt: { attempt += 1 },
            onExpiry: {
                XCTAssertEqual(attempt, 5)
                expiryCount += 1
                expired.fulfill()
            })
        await fulfillment(of: [expired], timeout: 2)
        XCTAssertThrowsError(try lease.check())
        XCTAssertEqual(expiryCount, 1)
    }

    func testTimeoutReturnsBeforeUncooperativeCallbackAndNeverPublishesItsLateValue() async {
        let started = expectation(description: "dependency started")
        let returned = expectation(description: "caller returned before dependency")
        let lateFinished = expectation(description: "late dependency finished")
        let gate = LaunchDeadlineTestGate(started: started)
        var published = false
        var events: [String] = []
        let lease = CloudLaunchDeadline(timeout: 0.1,
            invalidateAttempt: { events.append("invalidated") },
            onExpiry: { events.append("terminal") })
        let task = Task { @MainActor in
            defer { returned.fulfill() }
            do {
                _ = try await lease.run {
                    await gate.wait()
                    lateFinished.fulfill()
                    return "late"
                }
                published = true
                XCTFail("A late callback cannot authorize publication")
            } catch { XCTAssertEqual(error as? CloudLaunchDeadlineError, .expired) }
        }
        await fulfillment(of: [started, returned], timeout: 2, enforceOrder: true)
        XCTAssertFalse(published)
        XCTAssertEqual(events, ["invalidated", "terminal"])
        gate.release()
        await fulfillment(of: [lateFinished], timeout: 2)
        await task.value
        XCTAssertFalse(published)
        XCTAssertEqual(events, ["invalidated", "terminal"])
    }

    func testCancellationReleasesCallerWithoutExpiryOrWaitingForDependency() async {
        let started = expectation(description: "dependency started")
        let returned = expectation(description: "cancelled caller returned")
        let gate = LaunchDeadlineTestGate(started: started)
        var expiryCount = 0
        let lease = CloudLaunchDeadline(timeout: 30,
            invalidateAttempt: { XCTFail("Caller cancellation is not deadline expiry") },
            onExpiry: { expiryCount += 1 })
        let task = Task { @MainActor in
            defer { returned.fulfill() }
            do {
                _ = try await lease.run { await gate.wait(); return 1 }
                XCTFail("Cancelled launch must not succeed")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(expiryCount, 0)
        gate.release()
        await task.value
        XCTAssertThrowsError(try lease.check()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testPostAwaitValidationRejectsAChangedMountLease() async {
        let started = expectation(description: "dependency started")
        let gate = LaunchDeadlineTestGate(started: started)
        var active = true
        var validationCount = 0
        let lease = CloudLaunchDeadline(timeout: 30, invalidateAttempt: {}, onExpiry: {})
        defer { lease.cancel() }
        let task = Task { @MainActor in
            try await lease.run(validate: {
                validationCount += 1
                guard active else { throw LaunchDeadlineTestError.staleMount }
            }) { await gate.wait(); return 1 }
        }
        await fulfillment(of: [started], timeout: 2)
        active = false
        gate.release()
        do {
            _ = try await task.value
            XCTFail("Changed mount lease must reject an otherwise successful read")
        } catch { XCTAssertEqual(error as? LaunchDeadlineTestError, .staleMount) }
        XCTAssertGreaterThanOrEqual(validationCount, 3)
    }

    func testSuccessfulFinishDisarmsExpiryAndCannotBeReused() async throws {
        let clock = LaunchDeadlineTestClock()
        let lease = CloudLaunchDeadline(timeout: 12,
            invalidateAttempt: { XCTFail("Completed launch cannot expire") },
            onExpiry: { XCTFail("Completed launch cannot change terminal UI") },
            now: { clock.value })
        _ = try await lease.run { 1 }
        try lease.finish()
        clock.value = 100
        XCTAssertThrowsError(try lease.check()) {
            XCTAssertEqual($0 as? CloudLaunchDeadlineError, .finished)
        }
        lease.cancel()
    }

    func testPostAwaitValidationAlsoRejectsAStaleDependencyError() async {
        let started = expectation(description: "dependency started")
        let gate = LaunchDeadlineTestGate(started: started)
        var active = true
        let lease = CloudLaunchDeadline(timeout: 30, invalidateAttempt: {}, onExpiry: {})
        defer { lease.cancel() }
        let task = Task { @MainActor in
            try await lease.run(validate: {
                guard active else { throw LaunchDeadlineTestError.staleMount }
            }) { () async throws -> Int in
                await gate.wait()
                throw LaunchDeadlineTestError.dependencyFailed
            }
        }
        await fulfillment(of: [started], timeout: 2)
        active = false
        gate.release()
        do {
            _ = try await task.value
            XCTFail("A stale read cannot present its error on the current launch")
        } catch { XCTAssertEqual(error as? LaunchDeadlineTestError, .staleMount) }
    }

    func testFinishCannotDisarmWhileAnOperationStillOwnsACandidate() async throws {
        let started = expectation(description: "candidate held")
        let gate = LaunchDeadlineTestGate(started: started)
        let lease = CloudLaunchDeadline(timeout: 30, invalidateAttempt: {}, onExpiry: {})
        defer { lease.cancel() }
        let task = Task { @MainActor in try await lease.run { await gate.wait(); return 1 } }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertThrowsError(try lease.finish()) {
            XCTAssertEqual($0 as? CloudLaunchDeadlineError, .operationsInFlight)
        }
        gate.release()
        _ = try await task.value
        try lease.finish()
    }

    func testExpiryDoesNotFalselyProveAnUncooperativeCandidateWasReleased() async {
        let started = expectation(description: "candidate held")
        let returned = expectation(description: "deadline returned")
        let released = expectation(description: "candidate finally released")
        let gate = LaunchDeadlineTestGate(started: started)
        let state = LaunchDeadlineCandidateState()
        let lease = CloudLaunchDeadline(timeout: 0.1, invalidateAttempt: {}, onExpiry: {})
        let task = Task { @MainActor in
            defer { returned.fulfill() }
            do {
                _ = try await lease.run {
                    let candidate = LaunchDeadlineCandidate(onDeinit: { released.fulfill() })
                    state.candidate = candidate
                    await gate.wait()
                    withExtendedLifetime(candidate) {}
                    return 1
                }
                XCTFail("Deadline must reject held candidate")
            } catch { XCTAssertEqual(error as? CloudLaunchDeadlineError, .expired) }
        }
        await fulfillment(of: [started, returned], timeout: 2, enforceOrder: true)
        XCTAssertNotNil(state.candidate, "Host must independently wait for old containers before fallback")
        gate.release()
        await fulfillment(of: [released], timeout: 2)
        await task.value
        XCTAssertNil(state.candidate)
    }

    func testInvalidBudgetsFailClosedWithoutStartingAnOperation() async {
        for timeout in [Double.nan, Double.infinity, -1, 0] {
            var expired = 0
            let lease = CloudLaunchDeadline(timeout: timeout, invalidateAttempt: {},
                onExpiry: { expired += 1 })
            do {
                _ = try await lease.run { XCTFail("Invalid budget cannot authorize work"); return 1 }
                XCTFail("Invalid budget must fail")
            } catch { XCTAssertEqual(error as? CloudLaunchDeadlineError, .expired) }
            XCTAssertEqual(expired, 1)
        }
    }
}

@MainActor private final class LaunchDeadlineTestClock { var value: TimeInterval = 0 }
private enum LaunchDeadlineTestError: Error, Equatable { case staleMount, dependencyFailed }

@MainActor
private final class LaunchDeadlineTestGate {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor private final class LaunchDeadlineCandidateState {
    weak var candidate: LaunchDeadlineCandidate?
}
private final class LaunchDeadlineCandidate {
    let onDeinit: () -> Void
    init(onDeinit: @escaping () -> Void) { self.onDeinit = onDeinit }
    deinit { onDeinit() }
}
