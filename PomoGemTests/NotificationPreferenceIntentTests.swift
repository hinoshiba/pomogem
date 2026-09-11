import XCTest
@testable import PomoGem

@MainActor
final class NotificationPreferenceIntentTests: XCTestCase {
    func testOffDuringAuthorizationRefreshRejectsOldOnWithoutRequestingPermission() async {
        let gate = NotificationPreferenceIntentGate()
        let refresh = AuthorizationLatch(started: expectation(description: "refresh started"))
        let onIntent = gate.begin(.dailyReminder)
        var permissionRequestCount = 0
        let oldOn = Task {
            await gate.authorizeUpdate(
                .dailyReminder, intent: onIntent, enabled: true,
                refreshAuthorization: { await refresh.wait() },
                requestAuthorization: {
                    permissionRequestCount += 1
                    return true
                }
            )
        }
        await fulfillment(of: [refresh.started], timeout: 3)

        let offIntent = gate.begin(.dailyReminder)
        let mayDisable = await gate.authorizeUpdate(
            .dailyReminder, intent: offIntent, enabled: false,
            refreshAuthorization: { XCTFail("Off must not await authorization"); return false },
            requestAuthorization: { XCTFail("Off must not request authorization"); return false }
        )
        XCTAssertEqual(mayDisable, true)
        refresh.resume(false)
        let obsoleteResult = await oldOn.value
        XCTAssertNil(obsoleteResult)
        XCTAssertEqual(permissionRequestCount, 0)
        XCTAssertTrue(gate.isCurrent(.dailyReminder, intent: offIntent))
    }

    func testOffDuringPermissionPromptRejectsItsLateGrant() async {
        let gate = NotificationPreferenceIntentGate()
        let prompt = AuthorizationLatch(started: expectation(description: "prompt started"))
        let onIntent = gate.begin(.wrapped)
        let oldOn = Task {
            await gate.authorizeUpdate(
                .wrapped, intent: onIntent, enabled: true,
                refreshAuthorization: { false },
                requestAuthorization: { await prompt.wait() }
            )
        }
        await fulfillment(of: [prompt.started], timeout: 3)
        let offIntent = gate.begin(.wrapped)
        prompt.resume(true)
        let obsoleteResult = await oldOn.value
        XCTAssertNil(obsoleteResult)
        XCTAssertTrue(gate.isCurrent(.wrapped, intent: offIntent))
    }

    func testChangingWrappedDoesNotSupersedeDailyReminderAuthorization() async {
        let gate = NotificationPreferenceIntentGate()
        let refresh = AuthorizationLatch(started: expectation(description: "daily refresh started"))
        let dailyIntent = gate.begin(.dailyReminder)
        let daily = Task {
            await gate.authorizeUpdate(
                .dailyReminder, intent: dailyIntent, enabled: true,
                refreshAuthorization: { await refresh.wait() },
                requestAuthorization: { XCTFail("Already authorized"); return false }
            )
        }
        await fulfillment(of: [refresh.started], timeout: 3)
        _ = gate.begin(.wrapped)
        refresh.resume(true)
        let dailyResult = await daily.value
        XCTAssertEqual(dailyResult, true)
        XCTAssertTrue(gate.isCurrent(.dailyReminder, intent: dailyIntent))
    }

    func testCancelledAuthorizationCannotApplyItsLateResult() async {
        let gate = NotificationPreferenceIntentGate()
        let prompt = AuthorizationLatch(started: expectation(description: "cancelled prompt started"))
        let intent = gate.begin(.dailyReminder)
        let update = Task {
            await gate.authorizeUpdate(
                .dailyReminder, intent: intent, enabled: true,
                refreshAuthorization: { false },
                requestAuthorization: { await prompt.wait() }
            )
        }
        await fulfillment(of: [prompt.started], timeout: 3)
        update.cancel()
        prompt.resume(true)
        let cancelledResult = await update.value
        XCTAssertNil(cancelledResult)
    }

    func testFocusReturnOffSupersedesBothPendingAuthorizationStages() async {
        for waitsForPrompt in [false, true] {
            let gate = NotificationPreferenceIntentGate()
            let authorization = AuthorizationLatch(started: expectation(description: "focus authorization started"))
            let onIntent = gate.begin(.focusReturnReminder)
            var requests = 0
            let oldOn = Task {
                await gate.authorizeUpdate(
                    .focusReturnReminder, intent: onIntent, enabled: true,
                    refreshAuthorization: {
                        if waitsForPrompt { return false }
                        return await authorization.wait()
                    },
                    requestAuthorization: {
                        requests += 1
                        return await authorization.wait()
                    }
                )
            }
            await fulfillment(of: [authorization.started], timeout: 3)
            let offIntent = gate.begin(.focusReturnReminder)
            authorization.resume(true)
            let obsoleteResult = await oldOn.value
            XCTAssertNil(obsoleteResult)
            XCTAssertTrue(gate.isCurrent(.focusReturnReminder, intent: offIntent))
            XCTAssertEqual(requests, waitsForPrompt ? 1 : 0)
        }
    }

    func testPassiveSettingChangesDoNotCancelFocusReturnAuthorization() async {
        let gate = NotificationPreferenceIntentGate()
        let prompt = AuthorizationLatch(started: expectation(description: "independent focus prompt started"))
        let intent = gate.begin(.focusReturnReminder)
        let focusUpdate = Task {
            await gate.authorizeUpdate(
                .focusReturnReminder, intent: intent, enabled: true,
                refreshAuthorization: { false },
                requestAuthorization: { await prompt.wait() }
            )
        }
        await fulfillment(of: [prompt.started], timeout: 3)
        _ = gate.begin(.dailyReminder)
        _ = gate.begin(.wrapped)
        prompt.resume(true)
        let focusResult = await focusUpdate.value
        XCTAssertEqual(focusResult, true)
        XCTAssertTrue(gate.isCurrent(.focusReturnReminder, intent: intent))
    }
}

@MainActor
private final class AuthorizationLatch {
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Bool, Never>?

    init(started: XCTestExpectation) {
        self.started = started
    }

    func wait() async -> Bool {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }

    func resume(_ result: Bool) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}
