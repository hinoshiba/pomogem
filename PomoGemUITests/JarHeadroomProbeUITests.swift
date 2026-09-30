import XCTest

/// Docs/GemExperienceDesign.md §7.5 and Docs/JarOrientationGravity.md (F3
/// review nit, 2026-09-29): the mouth headroom invariant (at least 15 % of
/// the interior height free under the mouth, the minimum over the first
/// settle and ten full-strength shakes) measured by the app's own settle
/// probe (`POMOGEM_UI_TEST_SETTLE_PROBE`), for the two fixtures closest to
/// it. Before, this was a manual step at each integration; the unit replica
/// (`JarHeadroomReplica`) reads about five points lower and guards only a
/// 0.10 floor.
///
/// The probe runs in the Debug showcase jar with the phone upright (no
/// gravity input), so every settle rests on the floor (`offFloor=0`). The
/// stress fixture never idles (its three overflowing gems wait for a fusion
/// owner the fixture has none of), so each of its settles is the probe's
/// 20 s timeout: about four minutes.
@MainActor
final class JarHeadroomProbeUITests: XCTestCase {
    private var activeApp: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication().terminate()
    }

    override func tearDownWithError() throws {
        activeApp?.terminate()
        activeApp = nil
    }

    func testTheWorstCaseFixtureKeepsItsMouthHeadroomInTheAppsSettleProbe() throws {
        try verifyHeadroom(fixture: "worstcase", timeout: 240)
    }

    func testTheStressFixtureKeepsItsMouthHeadroomInTheAppsSettleProbe() throws {
        try verifyHeadroom(fixture: "stress", timeout: 330)
    }

    private func verifyHeadroom(fixture: String, timeout: TimeInterval) throws {
        let app = XCUIApplication()
        activeApp = app
        app.launchEnvironment["POMOGEM_LOCAL_PREVIEW"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_MODE"] = "1"
        app.launchEnvironment["POMOGEM_UI_TEST_GEM_SHOWCASE"] = fixture
        app.launchEnvironment["POMOGEM_UI_TEST_SETTLE_PROBE"] = "10"
        PomoGemUITestLanguage.configureJapanese(app)
        app.launch()

        let probe = app.staticTexts["jar.settle-probe"]
        XCTAssertTrue(probe.waitForExistence(timeout: 20), "\(fixture): the settle probe runs")
        let finished = expectation(
            for: NSPredicate(format: "label BEGINSWITH %@", "settle-min"),
            evaluatedWith: probe
        )
        wait(for: [finished], timeout: timeout)

        let summary = probe.label
        let attachment = XCTAttachment(string: summary)
        attachment.name = "\(fixture) settle probe"
        attachment.lifetime = .keepAlways
        add(attachment)
        let fields = Dictionary(
            uniqueKeysWithValues: summary.split(separator: " ").compactMap { field -> (String, String)? in
                let parts = field.split(separator: "=", maxSplits: 1)
                return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
            }
        )
        let headroom = try XCTUnwrap(fields["headroom"].flatMap(Double.init), "\(fixture): \(summary)")
        let settles = try XCTUnwrap(fields["settles"].flatMap(Int.init), "\(fixture): \(summary)")
        let offFloor = try XCTUnwrap(fields["offFloor"].flatMap(Int.init), "\(fixture): \(summary)")
        XCTAssertEqual(settles, 11, "\(fixture): the first settle and ten shaken ones")
        XCTAssertEqual(offFloor, 0, "\(fixture): upright, every settle rests on the floor")
        XCTAssertGreaterThanOrEqual(headroom, 0.15, "\(fixture): \(summary)")
    }
}
