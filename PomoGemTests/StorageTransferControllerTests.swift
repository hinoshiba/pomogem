import XCTest
@testable import PomoGem

@MainActor
final class StorageTransferControllerTests: XCTestCase {
    func testUninstallReleasesRootAndItsRetiringContainer() throws {
        let controller = StorageTransferController()
        let lifetimes = PersistenceContainerLifetimeTracker<TransferControllerContainer>()
        var owner: TransferControllerOwner? = TransferControllerOwner(controller: controller)
        weak var retainedOwner = owner
        weak var retainedContainer = owner?.container
        lifetimes.track(owner!.container)
        let registrationID = owner!.install()

        // Match Root's ownership: its controller stores an operation capturing
        // Root, which owns both that controller and the mounted container.
        owner = nil
        XCTAssertNotNil(retainedOwner)
        XCTAssertNotNil(retainedContainer)
        XCTAssertThrowsError(try lifetimes.requireAllReleased())

        controller.uninstall(registrationID: registrationID)
        XCTAssertNil(retainedOwner)
        XCTAssertNil(retainedContainer)
        try lifetimes.requireAllReleased()
        XCTAssertFalse(controller.isAvailable)
        controller.start(.enableCloudKeepingCloud)
        XCTAssertFalse(controller.isStarting)
    }

    func testReappearingRootReinstallsAndStaleDisappearanceCannotDetachIt() async {
        let controller = StorageTransferController()
        let oldRegistration = controller.install { _ in XCTFail("Old Root must be detached") }
        controller.uninstall(registrationID: oldRegistration)
        XCTAssertFalse(controller.isAvailable)

        let invoked = expectation(description: "reappearing Root accepted choice")
        _ = controller.install { _ in invoked.fulfill() }
        controller.uninstall(registrationID: oldRegistration)
        XCTAssertTrue(controller.isAvailable)
        controller.start(.enableCloudKeepingCloud)
        await fulfillment(of: [invoked], timeout: 3)
        XCTAssertTrue(controller.isStarting)
    }

    func testUninstallPreservesAcceptedOperationAndReleasesItsContainerAfterHandoff() async {
        let controller = StorageTransferController()
        let lifetimes = PersistenceContainerLifetimeTracker<TransferControllerContainer>()
        let gate = TransferControllerGate(started: expectation(description: "accepted operation entered"))
        let returned = expectation(description: "accepted operation finished handoff")
        var owner: TransferControllerOwner? = TransferControllerOwner(controller: controller)
        weak var retainedOwner = owner
        weak var retainedContainer = owner?.container
        lifetimes.track(owner!.container)
        let registrationID = controller.install { [acceptedOwner = owner!] _ in
            await gate.wait()
            XCTAssertFalse(Task.isCancelled, "View disappearance must not cancel a confirmed transfer")
            acceptedOwner.operationCount += 1
            returned.fulfill()
        }
        controller.start(.enableCloudKeepingCloud)
        await fulfillment(of: [gate.started], timeout: 3)
        owner = nil
        controller.uninstall(registrationID: registrationID)
        XCTAssertTrue(controller.isStarting)
        XCTAssertFalse(controller.isAvailable)
        XCTAssertNotNil(retainedOwner)
        XCTAssertNotNil(retainedContainer)
        XCTAssertTrue(lifetimes.hasLiveContainers, "Retirement must still wait for a confirmed operation")

        controller.install { _ in XCTFail("Reinstallation cannot unlock the accepted operation") }
        controller.start(.disableCloudKeepingCopy)
        gate.release()
        await fulfillment(of: [returned], timeout: 3)
        await waitUntil { retainedOwner == nil }
        XCTAssertNil(retainedContainer)
        XCTAssertFalse(lifetimes.hasLiveContainers)
        XCTAssertTrue(controller.isStarting, "The host still owns the durable transfer boundary")
    }

    /// The error is shown on its own under 「iCloudと保存先」, so the shared
    /// timer message must say that the switch did not happen.
    func testTimerHistoryFailureNamesTheSwitchThatDidNotHappen() async {
        let controller = StorageTransferController()
        controller.install({ _ in throw FocusCloudSyncError.timerHistoryRequiresMaintenance },
                           dataset: { _ in throw FocusCloudSyncError.timerHistoryRequiresMaintenance })
        let expected = "タイマーの履歴を確認できなかったため、保存先を切り替えられませんでした。少し時間をおいてから、もう一度お試しください。解決しない場合は、設定のサポートからお問い合わせください。"

        controller.start(.enableCloudKeepingCloud)
        await waitUntil { !controller.isStarting }
        XCTAssertEqual(controller.error, expected)

        controller.startDataset(.refreshFromCloud, policy: .standard)
        await waitUntil { !controller.isStarting }
        XCTAssertEqual(controller.error, expected)

        for other: Error in [FocusCloudSyncError.invalidPayload, StorageTransferError.activeTimer] {
            XCTAssertEqual(StorageTransferController.failureMessage(for: other), other.localizedDescription)
        }
    }

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
        controller.start(.disableCloudKeepingCopy)
        XCTAssertNil(controller.error)
        XCTAssertTrue(controller.isStarting)
        await fulfillment(of: [gate.started], timeout: 3)
        XCTAssertEqual(choices, [.enableCloudKeepingCloud, .disableCloudKeepingCopy])
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

    func testUnavailableReplacementCannotInvokeEvenAnInstalledOperation() async {
        let controller = StorageTransferController()
        var calls = 0
        controller.install { _ in calls += 1 }
        controller.start(.enableCloudReplacingCloud)
        await Task.yield()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(controller.isStarting)
        XCTAssertTrue(controller.isAvailable)
        XCTAssertEqual(controller.error, StorageTransferReleaseError.cloudReplacementUnavailable.localizedDescription)
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
private final class TransferControllerContainer {}

@MainActor
private final class TransferControllerOwner {
    let controller: StorageTransferController
    let container = TransferControllerContainer()
    var operationCount = 0

    init(controller: StorageTransferController) { self.controller = controller }

    func install() -> UUID {
        controller.install { [self] _ in
            operationCount += 1
            withExtendedLifetime(container) {}
        }
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
