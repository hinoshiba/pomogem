import XCTest
@testable import PomoGem

/// A focus or break that reaches its end with the app on screen rings until
/// stopped. These tests replay the order in which FocusView and
/// BreakTimerView see scene phases and permission refreshes, including the
/// cold-launch order that left a recovered break silent.
final class TimerForegroundResolutionTests: XCTestCase {
    // MARK: - The gate

    /// The regression. A recovered break's view appeared while the
    /// cold-launched scene was still inactive. Its `.task` copy kept reading
    /// `.inactive` after every `await`, and its late "current = (phase ==
    /// .active)" writes landed after the activation had opened the gate.
    func testRefreshesStartedBeforeActivationCannotCloseTheGateAfterIt() {
        var gate = TimerForegroundResolutionGate()
        // prepareBreak, before its first suspension: the scene is inactive.
        gate.observeAppearance(sceneIsActive: false)
        let prepareToken = gate.generation

        // The scene becomes active while prepareBreak is suspended, and the
        // onChange refresh finishes first.
        let activationToken = gate.observeScene(isActive: true)
        XCTAssertTrue(gate.finishAuthorizationRefresh(startedIn: activationToken))
        XCTAssertTrue(gate.allowsForegroundResolution(scenePhaseIsActive: true))

        // prepareBreak's refresh, then refreshNotificationScheduling's, both
        // begun in the older generation, finish afterwards.
        XCTAssertFalse(gate.finishAuthorizationRefresh(startedIn: prepareToken))
        XCTAssertFalse(gate.finishAuthorizationRefresh(startedIn: prepareToken))
        XCTAssertTrue(
            gate.allowsForegroundResolution(scenePhaseIsActive: true),
            "A stale refresh must leave the gate open: the ticker must still ring at 00:00"
        )
    }

    func testAViewThatAppearsActiveOpensAfterItsFirstRefresh() {
        var gate = TimerForegroundResolutionGate()
        gate.observeAppearance(sceneIsActive: true)
        XCTAssertFalse(
            gate.allowsForegroundResolution(scenePhaseIsActive: true),
            "Permission must be re-read before a cue is chosen"
        )
        let token = gate.generation
        XCTAssertTrue(gate.finishAuthorizationRefresh(startedIn: token))
        XCTAssertTrue(gate.allowsForegroundResolution(scenePhaseIsActive: true))
    }

    func testARefreshThatFinishesAfterLeavingActiveDoesNotOpen() {
        var gate = TimerForegroundResolutionGate()
        gate.observeAppearance(sceneIsActive: true)
        let token = gate.generation
        gate.observeScene(isActive: false)
        XCTAssertFalse(gate.finishAuthorizationRefresh(startedIn: token))
        XCTAssertFalse(gate.allowsForegroundResolution(scenePhaseIsActive: false))
        XCTAssertFalse(
            gate.allowsForegroundResolution(scenePhaseIsActive: true),
            "Background or inactive must never consume an end: the OS notification is still pending"
        )
    }

    func testARefreshWhileInactiveNeverOpens() {
        var gate = TimerForegroundResolutionGate()
        gate.observeAppearance(sceneIsActive: false)
        XCTAssertFalse(gate.finishAuthorizationRefresh(startedIn: gate.generation))
        XCTAssertFalse(gate.authorizationIsCurrent)
    }

    func testLeavingActiveClosesAnOpenGate() {
        var gate = TimerForegroundResolutionGate()
        gate.observeAppearance(sceneIsActive: true)
        gate.finishAuthorizationRefresh(startedIn: gate.generation)
        gate.observeScene(isActive: false)
        XCTAssertFalse(gate.authorizationIsCurrent)
        let returnToken = gate.observeScene(isActive: true)
        XCTAssertFalse(
            gate.authorizationIsCurrent,
            "Each activation re-reads permission; the person may have changed it in Settings"
        )
        XCTAssertTrue(gate.finishAuthorizationRefresh(startedIn: returnToken))
    }

    func testAPhaseAlreadyDeliveredByOnChangeWinsOverTheAppearanceRead() {
        var gate = TimerForegroundResolutionGate()
        let token = gate.observeScene(isActive: true)
        gate.observeAppearance(sceneIsActive: false)
        XCTAssertTrue(gate.sceneIsActive)
        XCTAssertEqual(gate.generation, token)
        XCTAssertTrue(gate.finishAuthorizationRefresh(startedIn: token))
    }

    func testTheTickerStillNeedsItsOwnFreshPhase() {
        var gate = TimerForegroundResolutionGate()
        gate.observeAppearance(sceneIsActive: true)
        gate.finishAuthorizationRefresh(startedIn: gate.generation)
        XCTAssertFalse(gate.allowsForegroundResolution(scenePhaseIsActive: false))
    }

    func testClosingFencesEveryCallbackAndAReappearanceReadsItsPhaseAgain() {
        var gate = TimerForegroundResolutionGate()
        gate.observeAppearance(sceneIsActive: true)
        let token = gate.generation
        gate.close()
        XCTAssertFalse(gate.finishAuthorizationRefresh(startedIn: token))
        XCTAssertFalse(gate.allowsForegroundResolution(scenePhaseIsActive: true))

        gate.observeAppearance(sceneIsActive: true)
        XCTAssertTrue(gate.sceneIsActive)
        XCTAssertTrue(gate.finishAuthorizationRefresh(startedIn: gate.generation))
    }
}
