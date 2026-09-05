import XCTest

/// Proves that an earned completion survives a real transaction failure and
/// remains idempotent across the user's protect/retry/relaunch journey.
@MainActor
final class FocusCompletionFailureRecoveryUITests: XCTestCase {
    private var storeName = ""
    private var activeApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
        XCUIApplication().terminate()
        storeName = "focus-save-fault-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        activeApp?.terminate()
        activeApp = nil
        guard !storeName.isEmpty else { return }
        cleanDedicatedStore()
    }

    func testFailedCompletionCanBeProtectedRetriedAndRelaunchedWithoutDuplication() throws {
        cleanDedicatedStore()

        let app = configuredApp(injectsSaveFailure: true)
        activeApp = app
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 12))
        dismissStaleRewardReceiptsIfNeeded(in: app)
        XCTAssertFalse(
            app.descendants(matching: .any)["home.pending-completion.retry"].exists,
            "A dedicated clean-store scenario must not inherit another test's deferred focus"
        )

        selectDemoDuration(in: app)
        let launcher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "12秒集中する")
        ).firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        launcher.tap()

        let saveError = app.descendants(matching: .any)["focus.completion-save.error"]
        XCTAssertTrue(
            saveError.waitForExistence(timeout: 60),
            "The explicit one-shot gate must reach the existing completion recovery UI"
        )
        XCTAssertTrue(saveError.label.contains("1回だけ失敗"), saveError.label)
        let retryInFocus = app.buttons["focus.completion-save.retry"]
        let protect = app.buttons["focus.completion-save.protect"]
        XCTAssertTrue(retryInFocus.exists)
        XCTAssertTrue(protect.exists)
        XCTAssertTrue(protect.isHittable)
        XCTAssertTrue(
            stopCompletionAlertIfPresented(in: app, timeout: 3),
            "A failed save must not make the foreground completion alert impossible to stop"
        )
        XCTAssertTrue(
            waitForNonExistence(
                app.buttons["focus.completion-alert.stop"],
                timeout: 3
            ),
            "Stopping the alert must retire its control"
        )
        XCTAssertTrue(saveError.exists)
        XCTAssertTrue(retryInFocus.exists)
        XCTAssertTrue(protect.exists)
        XCTAssertTrue(protect.isHittable)

        let failureAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        failureAttachment.name = "Injected completion save failure — recoverable"
        failureAttachment.lifetime = .keepAlways
        add(failureAttachment)

        protect.tap()

        let homeRetry = app.buttons["home.pending-completion.retry"]
        XCTAssertTrue(
            homeRetry.waitForExistence(timeout: 6),
            "Protecting the completion must expose an explicit retry on Home"
        )
        let protectedJar = try waitForJarProbe(in: app, expectedCount: 0, timeout: 6)
        XCTAssertTrue(protectedJar.records.isEmpty)
        _ = try waitForFixtureProbe(
            in: app,
            expected: [
                "grams": "0", "roots": "0", "loose": "0", "bodies": "0",
                "sessionRows": "0", "uniqueSessionIDs": "0"
            ],
            timeout: 6
        )

        homeRetry.tap()

        let savedJar = try waitForJarProbe(in: app, expectedCount: 1, timeout: 12)
        XCTAssertEqual(savedJar.records.count, 1)
        XCTAssertTrue(savedJar.records[0].hasSuffix(":250"), savedJar.rawValue)
        XCTAssertTrue(
            waitForHittable(app.buttons["瓶"], timeout: 6),
            "A successful retry must dismiss the recovery cover and reveal Home"
        )
        XCTAssertFalse(app.buttons["home.pending-completion.retry"].exists)
        _ = try waitForFixtureProbe(
            in: app,
            expected: [
                "grams": "250", "roots": "0", "loose": "1", "bodies": "1",
                "sessionRows": "1", "uniqueSessionIDs": "1"
            ],
            timeout: 8
        )

        dismissRewardBridgeIfPresent(in: app)
        let persistedRecords = savedJar.records
        app.terminate()

        // Relaunch with the fault still armed. If recovery was not retired,
        // the new process would fail that stale commit again and expose the
        // error screen instead of the stable one-pebble Home state.
        app.launch()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 12))
        XCTAssertFalse(
            app.descendants(matching: .any)["focus.completion-save.error"]
                .waitForExistence(timeout: 2),
            "A materialized completion must not be committed again after relaunch"
        )
        XCTAssertFalse(app.buttons["home.pending-completion.retry"].exists)

        let relaunchedJar = try waitForJarProbe(in: app, expectedCount: 1, timeout: 8)
        XCTAssertEqual(relaunchedJar.records, persistedRecords)
        XCTAssertEqual(relaunchedJar.records.count, 1)
        XCTAssertTrue(relaunchedJar.records[0].hasSuffix(":250"), relaunchedJar.rawValue)
        _ = try waitForFixtureProbe(
            in: app,
            expected: [
                "grams": "250", "roots": "0", "loose": "1", "bodies": "1",
                "sessionRows": "1", "uniqueSessionIDs": "1"
            ],
            timeout: 8
        )

        let relaunchAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        relaunchAttachment.name = "Completion retry relaunch — exactly one 250g pebble"
        relaunchAttachment.lifetime = .keepAlways
        add(relaunchAttachment)

        app.terminate()
        activeApp = nil
    }

    private func configuredApp(
        action: String = "normal",
        injectsSaveFailure: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TSUMIBEN_UI_TEST_PERSISTENT_STORE"] = storeName
        app.launchEnvironment["TSUMIBEN_UI_TEST_PERSISTENT_ACTION"] = action
        app.launchEnvironment["TSUMIBEN_UI_TEST_MODE"] = "1"
        if injectsSaveFailure {
            app.launchEnvironment[
                "TSUMIBEN_UI_TEST_FAULT_FOCUS_COMPLETION_SAVE_ONCE"
            ] = "1"
        }
        app.launchArguments += [
            "-AppleLanguages", "(ja)",
            "-AppleLocale", "ja_JP",
            "-review.requested-version", "1.0"
        ]
        return app
    }

    private func cleanDedicatedStore() {
        let cleaner = configuredApp(action: "clean")
        cleaner.launch()
        XCTAssertTrue(
            cleaner.staticTexts["fixture.40y.cleaned"].waitForExistence(timeout: 15),
            "The test must remove only its UUID-named CloudKit-free store"
        )
        cleaner.terminate()
    }

    private func selectDemoDuration(in app: XCUIApplication) {
        app.buttons["メニュー"].tap()
        let demoDuration = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demoDuration.waitForExistence(timeout: 4))
        demoDuration.tap()
        let close = app.buttons["home.menu.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 4))
        close.tap()
    }

    @discardableResult
    private func stopCompletionAlertIfPresented(
        in app: XCUIApplication,
        timeout: TimeInterval = 25
    ) -> Bool {
        let stop = app.buttons["focus.completion-alert.stop"]
        guard stop.waitForExistence(timeout: timeout) else { return false }
        XCTAssertEqual(stop.label, "終了アラートを止める")
        XCTAssertTrue(stop.isHittable)
        stop.tap()
        return true
    }

    private func dismissStaleRewardReceiptsIfNeeded(in app: XCUIApplication) {
        // The receipt store is process-local UserDefaults rather than part of
        // the UUID-named SwiftData fixture. Drain its bounded stale queue so a
        // prior interrupted UI test cannot cover this scenario's first frame.
        for _ in 0..<4 {
            let bridge = app.descendants(matching: .any)["reward.bridge"]
            guard bridge.waitForExistence(timeout: 1) else { return }
            let dismiss = app.buttons["休憩の提案を閉じる"]
            XCTAssertTrue(dismiss.waitForExistence(timeout: 2))
            dismiss.tap()
            XCTAssertTrue(waitForNonExistence(bridge, timeout: 2))
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 12))
        }
        XCTAssertFalse(app.descendants(matching: .any)["reward.bridge"].exists)
    }

    private func dismissRewardBridgeIfPresent(in app: XCUIApplication) {
        let bridge = app.descendants(matching: .any)["reward.bridge"]
        guard bridge.waitForExistence(timeout: 3) else { return }
        let dismiss = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 2))
        dismiss.tap()
        XCTAssertTrue(waitForNonExistence(bridge, timeout: 2))
    }

    private func waitForJarProbe(
        in app: XCUIApplication,
        expectedCount: Int,
        timeout: TimeInterval
    ) throws -> JarProbeSample {
        let probe = app.descendants(matching: .any)["jar.presentation.probe"]
        guard probe.waitForExistence(timeout: min(timeout, 5)) else {
            throw ProbeError.missing("jar.presentation.probe")
        }
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""
        repeat {
            latest = (probe.value as? String) ?? probe.label
            if let sample = JarProbeSample(rawValue: latest), sample.count == expectedCount {
                return sample
            }
            usleep(50_000)
        } while Date() < deadline
        throw ProbeError.didNotReachExpectedValue(
            identifier: "jar.presentation.probe",
            latest: latest
        )
    }

    private func waitForFixtureProbe(
        in app: XCUIApplication,
        expected: [String: String],
        timeout: TimeInterval
    ) throws -> [String: String] {
        let probe = app.descendants(matching: .any)["fixture.40y.probe"]
        guard probe.waitForExistence(timeout: min(timeout, 5)) else {
            throw ProbeError.missing("fixture.40y.probe")
        }
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""
        repeat {
            latest = (probe.value as? String) ?? probe.label
            let fields = probeFields(latest)
            if expected.allSatisfy({ fields[$0.key] == $0.value }) {
                return fields
            }
            usleep(50_000)
        } while Date() < deadline
        throw ProbeError.didNotReachExpectedValue(
            identifier: "fixture.40y.probe",
            latest: latest
        )
    }

    private func probeFields(_ rawValue: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: rawValue.split(separator: ";").compactMap {
            field -> (String, String)? in
            let pieces = field.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).map(String.init)
            guard pieces.count == 2 else { return nil }
            return (pieces[0], pieces[1])
        })
    }

    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { candidate, _ in
            guard let candidate = candidate as? XCUIElement else { return false }
            return candidate.exists && candidate.isHittable
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForNonExistence(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { candidate, _ in
            guard let candidate = candidate as? XCUIElement else { return true }
            return !candidate.exists
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}

private struct JarProbeSample {
    let count: Int
    let records: [String]
    let rawValue: String

    init?(rawValue: String) {
        let fields = Dictionary(uniqueKeysWithValues: rawValue
            .split(separator: ";")
            .compactMap { field -> (String, String)? in
                let pieces = field.split(
                    separator: "=",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                ).map(String.init)
                guard pieces.count == 2 else { return nil }
                return (pieces[0], pieces[1])
            })
        guard let rawCount = fields["count"],
              let count = Int(rawCount),
              let rawRecords = fields["records"]
        else { return nil }
        self.count = count
        records = rawRecords.isEmpty
            ? []
            : rawRecords.split(separator: ",").map(String.init)
        self.rawValue = rawValue
    }
}

private enum ProbeError: LocalizedError {
    case missing(String)
    case didNotReachExpectedValue(identifier: String, latest: String)

    var errorDescription: String? {
        switch self {
        case let .missing(identifier):
            "Missing UI-test probe: \(identifier)"
        case let .didNotReachExpectedValue(identifier, latest):
            "\(identifier) did not reach the expected state; latest=\(latest)"
        }
    }
}
