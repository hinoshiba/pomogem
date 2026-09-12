import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferControllerTests: XCTestCase {
    func testNoInstalledOperationCannotStart() {
        let controller = StorageTransferController()
        XCTAssertFalse(controller.isAvailable)
        controller.start(.enableCloudKeepingCloud)
        XCTAssertFalse(controller.isStarting)
        XCTAssertNil(controller.error)
    }

    func testPreparingRequestLocksSynchronouslyAndIgnoresRepeatedChoices() async {
        let controller = StorageTransferController()
        let gate = TransferControllerGate(started: expectation(description: "operation entered"))
        let returned = expectation(description: "operation returned")
        var choices: [StorageTransferChoice] = []
        controller.install { choice in
            choices.append(choice)
            await gate.wait()
            returned.fulfill()
        }
        XCTAssertTrue(controller.isAvailable)
        controller.start(.enableCloudKeepingCloud)
        XCTAssertTrue(controller.isStarting, "Block competing UI before the async account check begins")
        XCTAssertFalse(controller.isAvailable)
        controller.start(.enableCloudReplacingCloud)
        await fulfillment(of: [gate.started], timeout: 3)
        XCTAssertEqual(choices, [.enableCloudKeepingCloud])
        controller.start(.disableCloudKeepingCopy)
        gate.release()
        await fulfillment(of: [returned], timeout: 3)
        XCTAssertEqual(choices, [.enableCloudKeepingCloud])
    }

    func testAcceptedRequestStaysLockedEvenAfterOperationReturns() async {
        let controller = StorageTransferController()
        let accepted = expectation(description: "request accepted")
        var choices: [StorageTransferChoice] = []
        controller.install { choice in
            choices.append(choice)
            accepted.fulfill()
        }
        controller.start(.disableCloudKeepingCopy)
        await fulfillment(of: [accepted], timeout: 3)
        XCTAssertTrue(controller.isStarting, "Success waits for the host to unmount the source")
        XCTAssertFalse(controller.isAvailable)
        controller.start(.enableCloudReplacingCloud)
        await Task.yield()
        XCTAssertEqual(choices, [.disableCloudKeepingCopy], "A late queued activation must not create another request")
    }

    func testFailureRestoresAvailabilityAndNextRequestClearsOldError() async {
        let controller = StorageTransferController()
        var choices: [StorageTransferChoice] = []
        let gate = TransferControllerGate(started: expectation(description: "retry entered"))
        let returned = expectation(description: "retry returned")
        controller.install { choice in
            choices.append(choice)
            if choices.count == 1 { throw StorageTransferError.activeTimer }
            await gate.wait()
            returned.fulfill()
        }
        controller.start(.enableCloudKeepingCloud)
        await waitUntil { controller.error != nil }
        XCTAssertEqual(controller.error, StorageTransferError.activeTimer.localizedDescription)
        XCTAssertFalse(controller.isStarting)
        XCTAssertTrue(controller.isAvailable)
        controller.start(.enableCloudReplacingCloud)
        XCTAssertNil(controller.error)
        XCTAssertTrue(controller.isStarting)
        await fulfillment(of: [gate.started], timeout: 3)
        XCTAssertEqual(choices, [.enableCloudKeepingCloud, .enableCloudReplacingCloud])
        gate.release()
        await fulfillment(of: [returned], timeout: 3)
    }

    func testReinstallingOperationCannotUnlockAnAcceptedRequest() async {
        let controller = StorageTransferController()
        let accepted = expectation(description: "accepted")
        var newOperationCalls = 0
        controller.install { _ in accepted.fulfill() }
        controller.start(.enableCloudKeepingCloud)
        await fulfillment(of: [accepted], timeout: 3)
        controller.install { _ in newOperationCalls += 1 }
        controller.start(.enableCloudReplacingCloud)
        await Task.yield()
        XCTAssertEqual(newOperationCalls, 0)
        XCTAssertFalse(controller.isAvailable)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath,
                           line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Controller did not settle within its test deadline", file: file, line: line)
    }
}

@MainActor
private final class TransferControllerGate {
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
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
