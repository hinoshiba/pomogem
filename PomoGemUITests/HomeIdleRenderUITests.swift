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

    private func bodyEvaluations(_ probe: XCUIElement) -> Int? {
        guard let rawValue = probe.value as? String else { return nil }
        for field in rawValue.split(separator: ";") {
            let pieces = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pieces.count == 2, pieces[0] == "homeBodyEvaluations" {
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
