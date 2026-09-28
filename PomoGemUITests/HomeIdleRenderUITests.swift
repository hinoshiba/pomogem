import XCTest

/// Home is one very large view whose session projections are not cached, so
/// it must not re-render while nobody touches the phone. It used to observe
/// the whole Screen Time controller, whose foreground pass republished every
/// three seconds for every user and re-rendered Home about twenty times a
/// minute (home-01). The count comes from a Debug-only counter on
/// `HomeView.body`, read through the jar presentation probe.
@MainActor
final class HomeIdleRenderUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    func testIdleHomeDoesNotReRender() {
        let app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "0"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))
        let probe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertNotNil(bodyEvaluations(probe), "probe=\(String(describing: probe.value))")

        // Launch settles first (store backfill, the first projections). Quiet
        // means longer than the old three-second period, so a view that still
        // re-renders on a timer never looks settled and runs into the window
        // below instead.
        var last = bodyEvaluations(probe) ?? 0
        var quietSince = Date()
        let settleDeadline = Date().addingTimeInterval(45)
        while Date() < settleDeadline, Date().timeIntervalSince(quietSince) < 4.5 {
            pause(0.5)
            let current = bodyEvaluations(probe) ?? last
            if current != last {
                last = current
                quietSince = Date()
            }
        }

        let start = bodyEvaluations(probe) ?? 0
        pause(12)
        let end = bodyEvaluations(probe) ?? 0
        let summary = XCTAttachment(
            string: "settled after launch at \(start) evaluations; \(end - start) more during 12 s idle"
        )
        summary.name = "home-body-evaluations"
        summary.lifetime = .keepAlways
        add(summary)
        XCTAssertLessThanOrEqual(
            end - start,
            1,
            "Idle Home re-rendered \(end - start) times in 12 s (from \(start) to \(end))"
        )
    }

    /// device-verify-2 P4. On an iPhone 12 mini a manual entry's landing
    /// cost 103 ms of main-thread time in 210 ms and a 33 ms hitch: releasing
    /// the landed gem into the readout re-rendered all of Home (its session
    /// projection, canonical sessions and integrity checks) several times.
    /// The landing now updates only the jar's readout and core; Home's body
    /// must not run again because of it.
    func testAManualGemLandingUpdatesTheJarWithoutReRenderingHome() {
        let app = XCUIApplication()
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_AX5"] = "0"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 10))
        let probe = app.descendants(matching: .any)["jar.presentation.probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCTAssertEqual(field("homeLandings", probe), 0)

        app.buttons["メニュー"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "時間を手動で積む")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let thirtyMinutes = app.buttons["30分、300グラム加算"]
        XCTAssertTrue(thirtyMinutes.waitForExistence(timeout: 5))
        let confirm = app.buttons["manual.confirm"]
        for _ in 0..<3 where !confirm.exists {
            pause(0.6)
            if thirtyMinutes.isHittable { thirtyMinutes.tap() }
            _ = confirm.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        for _ in 0..<6 where !confirm.isHittable { app.swipeUp() }
        confirm.tap()

        // Saved when the Undo window ends; then the gem falls and lands.
        let landed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "homeLandings=1;"),
            object: probe
        )
        XCTAssertEqual(XCTWaiter.wait(for: [landed], timeout: 30), .completed,
                       "probe=\(String(describing: probe.value))")

        // What the landing itself set off happens within a few frames; the
        // toast it shows lasts 3 s and the one-time jar hint follows it, and
        // those are separate changes (the hint is one of Home's own).
        pause(1.5)
        let atLanding = field("homeBodyAtLanding", probe) ?? 0
        let soonAfter = field("homeBodyEvaluations", probe) ?? 0

        var last = field("homeBodyEvaluations", probe) ?? 0
        var quietSince = Date()
        let settleDeadline = Date().addingTimeInterval(20)
        while Date() < settleDeadline, Date().timeIntervalSince(quietSince) < 3 {
            pause(0.5)
            let current = field("homeBodyEvaluations", probe) ?? last
            if current != last {
                last = current
                quietSince = Date()
            }
        }
        let after = field("homeBodyEvaluations", probe) ?? 0
        let summary = XCTAttachment(
            string: "Home body evaluations: \(atLanding) at the landing, \(soonAfter) 1.5 s later, \(after) once settled"
        )
        summary.name = "home-body-evaluations-around-a-landing"
        summary.lifetime = .keepAlways
        add(summary)

        // The jar counts the gem once it has landed (dev-D7).
        let jar = app.descendants(matching: .any).matching(
            NSPredicate(format: "value CONTAINS %@", "記録した集中時間の質量：300グラム")
        ).firstMatch
        XCTAssertTrue(jar.waitForExistence(timeout: 5), "The jar must count the landed gem")
        XCTAssertEqual(soonAfter - atLanding, 0,
                       "The landing re-rendered Home \(soonAfter - atLanding) times (\(atLanding) → \(soonAfter))")
    }

    private func bodyEvaluations(_ probe: XCUIElement) -> Int? {
        field("homeBodyEvaluations", probe)
    }

    private func field(_ name: String, _ probe: XCUIElement) -> Int? {
        guard let rawValue = probe.value as? String else { return nil }
        for field in rawValue.split(separator: ";") {
            let pieces = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pieces.count == 2, pieces[0] == name {
                return Int(pieces[1])
            }
        }
        return nil
    }

    /// Waits without touching the app: no taps, no scrolling.
    private func pause(_ seconds: TimeInterval) {
        let idle = XCTestExpectation(description: "idle")
        idle.isInverted = true
        _ = XCTWaiter.wait(for: [idle], timeout: seconds)
    }
}
