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

    /// The twin for a completed focus, the landing people see most (review
    /// of #58). Releasing the timer gem's receipt enables the start button
    /// and continues past the card, which re-renders Home by design; it
    /// used to run in the landing callback, on the frames where the gem
    /// strikes. Now the readout counts the gem at once and Home's own work
    /// waits until the landing has settled: no Home pass between the
    /// landing and that settle, and the start button follows it.
    func testATimerGemLandingDefersHomesOwnWorkPastTheLanding() {
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

        let launcher = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "12秒集中する")).firstMatch
        let demo = app.buttons["12秒、DEMO"]
        for _ in 0..<3 where !launcher.exists {
            if !demo.exists {
                app.buttons["home.duration-picker"].tap()
                XCTAssertTrue(demo.waitForExistence(timeout: 4))
            }
            _ = waitUntilFrameSettles(demo, timeout: 3)
            demo.tap()
            _ = launcher.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(launcher.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntilFrameSettles(launcher))
        launcher.tap()
        stopCompletionAlertIfPresented(in: app)
        let dismissReward = app.buttons["休憩の提案を閉じる"]
        XCTAssertTrue(dismissReward.waitForExistence(timeout: 30), "The demo focus completes and offers its card")
        let jar = app.descendants(matching: .any)["瓶"]
        let beforeLanding = jar.value as? String ?? ""
        tapUntilGone(dismissReward)

        // The gem falls from the top and lands; Home then settles it.
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "homeLandings=1;", "homeSettles=1;"),
            object: probe
        )
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 20), .completed,
                       "probe=\(String(describing: probe.value))")
        let atLanding = field("homeBodyAtLanding", probe) ?? -1
        let atSettle = field("homeBodyAtSettle", probe) ?? -2
        let summary = XCTAttachment(
            string: "Home body evaluations: \(atLanding) at the landing, \(atSettle) when Home settled it"
        )
        summary.name = "home-body-evaluations-around-a-timer-landing"
        summary.lifetime = .keepAlways
        add(summary)
        XCTAssertEqual(atSettle, atLanding,
                       "The landing re-rendered Home \(atSettle - atLanding) times before it settled (\(atLanding) → \(atSettle))")

        // Then the receipt is released: the start button works again (back
        // on the default duration, so found by its identifier), and the jar
        // has counted the gem since it landed (dev-D7).
        let enabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND isEnabled == true"),
            object: app.buttons["home.focus-launcher"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 8), .completed)
        XCTAssertGreaterThan(field("homeBodyEvaluations", probe) ?? 0, atSettle,
                             "Releasing the receipt re-renders Home once the landing has settled")
        let counted = jar.value as? String ?? ""
        XCTAssertTrue(counted.contains("記録した集中時間の質量："), counted)
        XCTAssertNotEqual(counted, beforeLanding, "The jar counts the landed gem")
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
