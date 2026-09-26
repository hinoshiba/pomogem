import XCTest

/// Exercises the first decimal fusion through a real dirty-model rollback,
/// explicit retry and cold relaunch against a CloudKit-free persistent store.
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

    func testFailedAggregateRestoresExactSourcesThenRetriesAndRelaunchesOnce() throws {
        cleanDedicatedStore()

        let app = configuredApp(injectsAggregateSaveFailure: true)
        activeApp = app
        app.launch()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 12))
        assertNoRewardCardFromAnEarlierTest(in: app)
        selectDemoDuration(in: app)

        for expectedCount in 1 ... 9 {
            completeDemoFocusAndDismissReward(in: app)
            let sample = try waitForJarProbe(
                in: app,
                expectedCount: expectedCount,
                timeout: 8
            )
            assertLooseMeasuredPebbles(sample, expectedCount: expectedCount)
        }

        let firstNine = try waitForJarProbe(in: app, expectedCount: 9, timeout: 4)
        let firstNineIDs = Set(firstNine.entries.map(\.id))
        XCTAssertEqual(firstNineIDs.count, 9)

        startDemoFocus(in: app)
        stopCompletionAlertIfPresented(in: app)
        let dismissReward = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(
            dismissReward.waitForExistence(timeout: 60),
            "The tenth completion must commit before aggregate persistence is injected"
        )
        let completedFusion = app.descendants(matching: .any)["reward.fusion-progress"]
        XCTAssertTrue(completedFusion.waitForExistence(timeout: 3))
        XCTAssertTrue(completedFusion.label.contains("×10完成 10/10"), completedFusion.label)
        dismissReward.tap()

        let retry = app.buttons["jar.aggregate.persistence.retry"]
        XCTAssertTrue(
            waitForHittable(retry, timeout: 12),
            "The post-mutation injected failure must reach Home's existing retry affordance"
        )
        XCTAssertFalse(
            app.staticTexts["10粒を、ひとつに整理した"].exists,
            "An uncommitted aggregate must never be celebrated"
        )

        let restored = try waitForJarProbe(in: app, expectedCount: 10, timeout: 10)
        assertLooseMeasuredPebbles(restored, expectedCount: 10)
        let sourceIDs = Set(restored.entries.map(\.id))
        XCTAssertEqual(sourceIDs.count, 10)
        XCTAssertTrue(firstNineIDs.isSubset(of: sourceIDs))
        XCTAssertEqual(restored.entries.reduce(0) { $0 + $1.grams }, 2_500)

        _ = try waitForProbe(
            "fixture.40y.probe",
            in: app,
            expected: [
                "grams": "2500", "roots": "0", "loose": "10", "bodies": "10",
                "sessionRows": "10", "uniqueSessionIDs": "10"
            ],
            timeout: 10
        )
        _ = try waitForProbe(
            "aggregate.persistence.probe",
            in: app,
            expected: [
                "sessionRows": "10", "uniqueSessionIDs": "10",
                "legacyBakedSessionRows": "0", "looseSessionRows": "10",
                "aggregateRows": "0", "uniqueAggregateIDs": "0",
                "rootRows": "0", "uniqueRootIDs": "0", "logicalGrams": "2500"
            ],
            timeout: 10
        )

        // The fault is one-shot. If SpriteKit were not suspended after the
        // failure, an automatic second attempt would now succeed without the
        // user pressing the retry button.
        usleep(1_000_000)
        XCTAssertTrue(retry.exists)
        _ = try waitForProbe(
            "aggregate.persistence.probe",
            in: app,
            expected: ["aggregateRows": "0", "rootRows": "0", "looseSessionRows": "10"],
            timeout: 3
        )

        let failureAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        failureAttachment.name = "Aggregate save failure — exact ten sources restored"
        failureAttachment.lifetime = .keepAlways
        add(failureAttachment)

        retry.tap()
        let celebration = app.staticTexts["10粒を、ひとつに整理した"]
        XCTAssertTrue(
            celebration.waitForExistence(timeout: 12),
            "The explicit retry must persist before presenting the fusion celebration"
        )
        let continueButton = app.buttons["ここで休む"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 4))
        continueButton.tap()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 8))
        XCTAssertTrue(waitForNonExistence(retry, timeout: 4))

        let fused = try waitForJarProbe(in: app, expectedCount: 1, timeout: 10)
        let aggregateEntry = try XCTUnwrap(fused.entries.first)
        XCTAssertEqual(aggregateEntry.grams, 2_500)
        XCTAssertFalse(sourceIDs.contains(aggregateEntry.id))

        let committed = try waitForProbe(
            "aggregate.persistence.probe",
            in: app,
            expected: [
                "sessionRows": "10", "uniqueSessionIDs": "10",
                "legacyBakedSessionRows": "0", "looseSessionRows": "0",
                "aggregateRows": "1", "uniqueAggregateIDs": "1",
                "rootRows": "1", "uniqueRootIDs": "1",
                "rootID": aggregateEntry.id,
                "rootGrams": "2500", "rootPebbles": "10",
                "rootMeasured": "10", "rootManual": "0",
                "rootSourceIDCount": "10", "uniqueRootSourceIDs": "10",
                "logicalGrams": "2500"
            ],
            timeout: 12
        )
        XCTAssertEqual(sourceIDSet(from: committed["rootSourceIDs"]), sourceIDs)
        _ = try waitForProbe(
            "fixture.40y.probe",
            in: app,
            expected: ["grams": "2500", "roots": "1", "loose": "0", "bodies": "1"],
            timeout: 10
        )

        let persistedJarRecords = fused.records
        app.terminate()

        // Relaunch with the one-shot environment key armed again. Correctly
        // persisted state has no ten loose sources, so no second request should
        // consume it or expose the failure UI in the fresh process.
        app.launch()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 15))
        XCTAssertFalse(
            retry.waitForExistence(timeout: 2),
            "A committed deterministic aggregate must not be requested again after relaunch"
        )
        XCTAssertFalse(app.staticTexts["10粒を、ひとつに整理した"].exists)

        let relaunched = try waitForJarProbe(in: app, expectedCount: 1, timeout: 10)
        XCTAssertEqual(relaunched.records, persistedJarRecords)
        let relaunchedAudit = try waitForProbe(
            "aggregate.persistence.probe",
            in: app,
            expected: [
                "sessionRows": "10", "uniqueSessionIDs": "10",
                "legacyBakedSessionRows": "0", "looseSessionRows": "0",
                "aggregateRows": "1", "uniqueAggregateIDs": "1",
                "rootRows": "1", "uniqueRootIDs": "1",
                "rootID": aggregateEntry.id,
                "rootGrams": "2500", "rootPebbles": "10",
                "rootSourceIDCount": "10", "uniqueRootSourceIDs": "10",
                "logicalGrams": "2500"
            ],
            timeout: 12
        )
        XCTAssertEqual(sourceIDSet(from: relaunchedAudit["rootSourceIDs"]), sourceIDs)

        let relaunchAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        relaunchAttachment.name = "Aggregate retry relaunch — one stable 2500g root"
        relaunchAttachment.lifetime = .keepAlways
        add(relaunchAttachment)

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
        demoDuration.tap()
    }

    private func startDemoFocus(in app: XCUIApplication) {
        let launcher = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "12秒集中する")
        ).firstMatch
        XCTAssertTrue(launcher.waitForExistence(timeout: 6))
        XCTAssertTrue(launcher.isHittable)
        launcher.tap()
    }

    private func completeDemoFocusAndDismissReward(in app: XCUIApplication) {
        startDemoFocus(in: app)
        stopCompletionAlertIfPresented(in: app)
        let dismissReward = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(
            dismissReward.waitForExistence(timeout: 60),
            "Each seed completion must commit through the real focus UI"
        )
        dismissReward.tap()
        XCTAssertTrue(waitForHittable(app.buttons["メニュー"], timeout: 6))
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

    private func assertLooseMeasuredPebbles(
        _ sample: JarProbeSample,
        expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(sample.entries.count, expectedCount, file: file, line: line)
        XCTAssertEqual(Set(sample.entries.map(\.id)).count, expectedCount, file: file, line: line)
        XCTAssertTrue(sample.entries.allSatisfy { $0.grams == 250 }, file: file, line: line)
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

    private func sourceIDSet(from rawValue: String?) -> Set<String> {
        guard let rawValue, !rawValue.isEmpty else { return [] }
        return Set(rawValue.split(separator: ",").map(String.init))
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
