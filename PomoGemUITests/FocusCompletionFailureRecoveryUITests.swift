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
        assertNoRewardCardFromAnEarlierTest(in: app)
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

        let dismissReward = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismissReward.waitForExistence(timeout: 12))
        let pendingRewardJar = try waitForJarProbe(in: app, expectedCount: 0, timeout: 3)
        XCTAssertTrue(pendingRewardJar.records.isEmpty,
                      "The retried reward must wait outside the jar while its card is visible")
        dismissReward.tap()
        XCTAssertTrue(waitForNonExistence(dismissReward, timeout: 5))

        let savedJar = try waitForJarProbe(
            in: app, expectedCount: 1, timeout: 12, requiringLanding: true
        )
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

    func testRewardSelectedBreakSurvivesRelaunchWithoutRestartAndSkipIsFinal() throws {
        cleanDedicatedStore()
        let app = configuredApp()
        app.launchArguments += ["-focus.rest-cadence.v2", "reward-rest-relaunch-reset"]
        activeApp = app
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 12))
        assertNoRewardCardFromAnEarlierTest(in: app)
        selectDemoDuration(in: app)
        let launcher = app.buttons["home.focus-launcher"]
        XCTAssertTrue(waitForHittable(launcher, timeout: 5))
        launcher.tap()
        XCTAssertTrue(stopCompletionAlertIfPresented(in: app))
        let rest = app.buttons["5分休憩する"]
        XCTAssertTrue(waitForHittable(rest, timeout: 12))
        let selectedAt = Date()
        rest.tap()
        // Do not wait for the gem or break cover. Unit tests independently
        // freeze the exact pre-landing state; here kill the real UI as soon as
        // XCTest returns control after the user's selection.
        app.terminate()
        usleep(4_000_000)
        app.launch()
        XCTAssertTrue(app.staticTexts["休憩"].waitForExistence(timeout: 15))
        let countdown = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "残り[0-9]+分[0-9]+秒")
        ).firstMatch
        XCTAssertTrue(countdown.waitForExistence(timeout: 5))
        let label = countdown.label
        let regex = try NSRegularExpression(pattern: "残り([0-9]+)分([0-9]+)秒")
        let match = try XCTUnwrap(regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)))
        let minutes = try XCTUnwrap(Range(match.range(at: 1), in: label))
        let seconds = try XCTUnwrap(Range(match.range(at: 2), in: label))
        let remaining = try XCTUnwrap(Int(label[minutes])) * 60 + XCTUnwrap(Int(label[seconds]))
        XCTAssertLessThan(remaining, 296, "Time outside the process must count toward the selected break")
        XCTAssertEqual(Double(300 - remaining), Date().timeIntervalSince(selectedAt), accuracy: 4,
                       "Recovery must retain the original deadline, not restart five minutes")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Reward-selected rest — original countdown after relaunch"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let skip = app.buttons["休憩をスキップ"].firstMatch
        XCTAssertTrue(waitForHittable(skip, timeout: 5))
        skip.tap()
        XCTAssertTrue(waitForNonExistence(app.staticTexts["休憩"], timeout: 5))
        XCTAssertTrue(waitForHittable(launcher, timeout: 12))
        let landed = try waitForJarProbe(in: app, expectedCount: 1, timeout: 12)
        XCTAssertEqual(landed.records.count, 1)
        XCTAssertTrue(landed.records[0].hasSuffix(":250"))
        XCTAssertFalse(app.buttons["休憩の提案を閉じる"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(waitForHittable(launcher, timeout: 15))
        XCTAssertFalse(app.staticTexts["休憩"].exists, "A landed reward must not recreate a skipped break")
        let reopened = try waitForJarProbe(in: app, expectedCount: 1, timeout: 8)
        XCTAssertEqual(reopened.records, landed.records)
        XCTAssertFalse(app.buttons["休憩の提案を閉じる"].exists)
    }

    private func configuredApp(
        action: String = "normal",
        injectsSaveFailure: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["POMOGEM_UI_TEST_PERSISTENT_STORE"] = storeName
        app.launchEnvironment["POMOGEM_UI_TEST_PERSISTENT_ACTION"] = action
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        if injectsSaveFailure {
            app.launchEnvironment[
                "POMOGEM_UI_TEST_FAULT_FOCUS_COMPLETION_SAVE_ONCE"
            ] = "1"
        }
        PomoGemUITestLanguage.configureJapanese(app)
        app.launchArguments += [
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
        app.buttons["home.duration-picker"].tap()
        let demoDuration = app.buttons["12秒、DEMO"]
        XCTAssertTrue(demoDuration.waitForExistence(timeout: 4))
        demoDuration.tap()
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

    /// The app drops the reward receipts an earlier test's store left in
    /// UserDefaults whenever it opens a new or cleaned store
    /// (`UITestLocalStateIsolation`). Draining them here used to acknowledge
    /// a gem that could never land, which left the start button disabled.
    private func assertNoRewardCardFromAnEarlierTest(in app: XCUIApplication) {
        XCTAssertFalse(
            app.descendants(matching: .any)["reward.bridge"].waitForExistence(timeout: 1),
            "A new store must not show another test's completion card"
        )
    }

    private func waitForJarProbe(
        in app: XCUIApplication,
        expectedCount: Int,
        timeout: TimeInterval,
        requiringLanding: Bool = false
    ) throws -> JarProbeSample {
        let probe = app.descendants(matching: .any)["jar.presentation.probe"]
        guard probe.waitForExistence(timeout: min(timeout, 5)) else {
            throw ProbeError.missing("jar.presentation.probe")
        }
        let deadline = Date().addingTimeInterval(timeout)
        var latest = ""
        repeat {
            latest = (probe.value as? String) ?? probe.label
            if let sample = JarProbeSample(rawValue: latest),
               sample.count == expectedCount,
               !requiringLanding || sample.dropLanded {
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
    let dropLanded: Bool
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
        dropLanded = fields["dropLanded"] == "1"
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
