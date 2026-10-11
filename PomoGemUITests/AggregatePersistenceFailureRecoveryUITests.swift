import XCTest

/// Time crystals are a projection of saved source time, independent of a
/// foreground aggregate write. The legacy save fault is armed throughout;
/// original records and canonical display must survive a cold relaunch.
/// Internal rollback/retry behavior remains covered by HomeProjectionTests
/// and StrataMathTests.
@MainActor
final class AggregatePersistenceFailureRecoveryUITests: XCTestCase {
    private var storeName = ""
    private var activeApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 720
        XCUIApplication().terminate()
        storeName = "aggregate-save-fault-\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        activeApp?.terminate()
        activeApp = nil
        guard !storeName.isEmpty else { return }
        cleanDedicatedStore()
    }

    func testTimeCrystalAndOriginalRecordsSurviveWithoutForegroundAggregatePersistence() throws {
        cleanDedicatedStore()
        let app = configuredApp(injectsAggregateSaveFailure: true)
        activeApp = app
        app.launch()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 12))
        assertNoRewardCardFromAnEarlierTest(in: app)
        selectDemoDuration(in: app)

        for completion in 1...10 {
            startDemoFocus(in: app)
            stopCompletionAlertIfPresented(in: app)
            let dismiss = app.buttons["休憩の提案を閉じる"]
            XCTAssertTrue(dismiss.waitForExistence(timeout: 60))
            XCTAssertFalse(app.staticTexts["fusion.celebration.title"].exists,
                           "A saved session waits for its acknowledged landing")
            dismiss.tap()
            if completion == 10 {
                let celebration = app.staticTexts["fusion.celebration.title"]
                XCTAssertTrue(celebration.waitForExistence(timeout: 12))
                XCTAssertTrue(celebration.label.contains("4時間10分"), celebration.label)
                let close = app.buttons["fusion.celebration.close"]
                XCTAssertTrue(close.waitForExistence(timeout: 4))
                close.tap()
            }
            _ = try waitForJarProbe(in: app, expectedGrams: completion * 250, timeout: 10)
            XCTAssertTrue(waitForEnabled(app.buttons["home.focus-launcher"], timeout: 10))
            XCTAssertFalse(app.buttons["jar.aggregate.persistence.retry"].exists,
                           "A time display must not depend on a foreground aggregate save")
        }

        let formed = try waitForJarProbe(in: app, expectedGrams: 2_500, timeout: 10)
        XCTAssertEqual(formed.entries.count, 1)
        _ = try waitForProbe(
            "aggregate.persistence.probe", in: app,
            expected: ["sessionRows": "10", "uniqueSessionIDs": "10", "logicalGrams": "2500"],
            timeout: 12
        )
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Time crystal — original ten records preserved with legacy save fault armed"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
        app.launch()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 15))
        XCTAssertFalse(app.buttons["jar.aggregate.persistence.retry"].exists)
        XCTAssertFalse(app.staticTexts["fusion.celebration.title"].exists,
                       "Restoring saved time must not replay its celebration")
        let restored = try waitForJarProbe(in: app, expectedGrams: 2_500, timeout: 10)
        XCTAssertEqual(restored.records, formed.records)
        _ = try waitForProbe(
            "aggregate.persistence.probe", in: app,
            expected: ["sessionRows": "10", "uniqueSessionIDs": "10", "logicalGrams": "2500"],
            timeout: 12
        )
        app.terminate()
        activeApp = nil
    }

    private func configuredApp(
        action: String = "normal",
        injectsAggregateSaveFailure: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["POMOGEM_UI_TEST_PERSISTENT_STORE"] = storeName
        app.launchEnvironment["POMOGEM_UI_TEST_PERSISTENT_ACTION"] = action
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        if injectsAggregateSaveFailure {
            app.launchEnvironment["POMOGEM_UI_TEST_FAULT_AGGREGATE_SAVE_ONCE"] = "1"
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
        // A tap while the menu is still animating in can be dropped.
        XCTAssertTrue(waitForHittable(demoDuration, timeout: 3))
        demoDuration.tap()
    }

    private func demoLauncher(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "12秒集中する")
        ).firstMatch
    }

    private func startDemoFocus(in app: XCUIApplication) {
        let launcher = demoLauncher(in: app)
        if !launcher.waitForExistence(timeout: 2) {
            // 12秒、DEMO is Debug-only and never saved as the preferred
            // duration. Home restores the saved duration when it reappears or
            // its preferences change, which the first completion can do, so
            // pick the demo again (as DecimalFusionEndToEndUITests does). The
            // test is about aggregate persistence, not the demo choice.
            selectDemoDuration(in: app)
        }
        XCTAssertTrue(launcher.waitForExistence(timeout: 6))
        XCTAssertTrue(waitForHittable(launcher, timeout: 3))
        // The jar probe counts a gem while it falls, and Home enables the
        // start button only once the landing has settled; a tap before that
        // is ignored and no focus starts.
        XCTAssertTrue(
            waitForEnabled(launcher, timeout: 10),
            "The start button must come back once the last gem has landed"
        )
        launcher.tap()
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
        expectedGrams: Int,
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
            if let sample = JarProbeSample(rawValue: latest),
               sample.entries.count == 1,
               sample.entries.first?.grams == expectedGrams {
                return sample
            }
            usleep(50_000)
        } while Date() < deadline
        throw ProbeError.didNotReachExpectedValue(
            identifier: "jar.presentation.probe",
            latest: latest
        )
    }

    private func waitForProbe(
        _ identifier: String,
        in app: XCUIApplication,
        expected: [String: String],
        timeout: TimeInterval
    ) throws -> [String: String] {
        let probe = app.descendants(matching: .any)[identifier]
        guard probe.waitForExistence(timeout: min(timeout, 5)) else {
            throw ProbeError.missing(identifier)
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
        throw ProbeError.didNotReachExpectedValue(identifier: identifier, latest: latest)
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

    private func waitForEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND isEnabled == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }


}

private struct JarProbeSample {
    let count: Int
    let records: [String]
    let entries: [JarProbeEntry]
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

        let records = rawRecords.isEmpty
            ? []
            : rawRecords.split(separator: ",").map(String.init)
        let entries = records.compactMap { record -> JarProbeEntry? in
            let pieces = record.split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let grams = Int(pieces[1]) else { return nil }
            return JarProbeEntry(id: pieces[0], grams: grams)
        }
        guard entries.count == records.count else { return nil }

        self.count = count
        self.records = records
        self.entries = entries
        self.rawValue = rawValue
    }
}

private struct JarProbeEntry: Hashable {
    let id: String
    let grams: Int
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
