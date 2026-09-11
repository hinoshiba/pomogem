import SwiftData
import XCTest
@testable import PomoGem

@MainActor
final class ViewTaskScopeTests: XCTestCase {
    func testDisappearingViewReleasesContainerBeforeUncooperativeCallback() async throws {
        let scope = ViewTaskScope()
        let callback = ViewServiceCallback(started: expectation(description: "service waiting"))
        var container: ModelContainer? = try ModelContainer(
            for: Prefs.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        weak var retiredContainer = container
        let finished = expectation(description: "view released its context")
        var didWriteAfterDisappearance = false
        let task = try XCTUnwrap(scope.start { [container = container!] in
            defer { finished.fulfill() }
            do {
                try await CancellationResponsiveTaskWaiter.value {
                    await callback.wait()
                }
                container.mainContext.insert(Prefs())
                try container.mainContext.save()
                didWriteAfterDisappearance = true
            } catch is CancellationError {
                // The system callback itself deliberately remains pending.
            } catch {
                XCTFail("Unexpected service failure: \(error)")
            }
        })
        await fulfillment(of: [callback.started], timeout: 3)
        container = nil
        XCTAssertNotNil(retiredContainer)
        scope.cancelAll()
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertNil(retiredContainer, "A pending service must not retain the retired CloudKit container")
        XCTAssertFalse(didWriteAfterDisappearance)
        callback.finish()
        await task.value
        XCTAssertFalse(didWriteAfterDisappearance)
    }

    func testDiscardedViewRejectsLateStartsAndReappearanceDoesNotReviveOldWork() async throws {
        let scope = ViewTaskScope()
        let callback = ViewServiceCallback(started: expectation(description: "old service waiting"))
        let oldFinished = expectation(description: "old view stopped waiting")
        var results: [String] = []
        let old = try XCTUnwrap(scope.start {
            defer { oldFinished.fulfill() }
            do {
                try await CancellationResponsiveTaskWaiter.value { await callback.wait() }
                results.append("old")
            } catch { }
        })
        await fulfillment(of: [callback.started], timeout: 3)
        scope.cancelAll()
        XCTAssertNil(scope.start { results.append("discarded") })
        scope.activate()
        let current = try XCTUnwrap(scope.start { results.append("current") })
        await current.value
        await fulfillment(of: [oldFinished], timeout: 3)
        callback.finish()
        await old.value
        XCTAssertEqual(results, ["current"])
    }
}

@MainActor
private final class ViewServiceCallback {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        guard !isFinished else { return }
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func finish() {
        isFinished = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
