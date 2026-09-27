import XCTest
@testable import PomoGem

/// A focus or break that reaches its end with the app on screen rings until
/// stopped. Only an end that had already passed when the timer was recovered
/// is marked once or shown silently. These tests replay the order in which
/// FocusView and BreakTimerView see scene phases and permission refreshes,
/// including the cold-launch order that left a recovered break silent.
final class TimerForegroundResolutionTests: XCTestCase {
    private typealias Cue = TimerCompletionForegroundFeedbackPolicy.Cue

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

    // MARK: - Recovered ends

    func testARecoveredTimerFoundRunningIsALiveEnd() {
        var activation = TimerRecoveryActivation(isRecovery: true)
        activation.observeRunning()
        XCTAssertFalse(activation.consumeRecoveredAfterExpiration())
    }

    func testARecoveredTimerThatHadEndedIsAnsweredOnce() {
        var activation = TimerRecoveryActivation(isRecovery: true)
        XCTAssertTrue(activation.consumeRecoveredAfterExpiration())
        XCTAssertFalse(activation.consumeRecoveredAfterExpiration())
    }

    func testANewTimerIsNeverARecovery() {
        var activation = TimerRecoveryActivation(isRecovery: false)
        XCTAssertFalse(activation.consumeRecoveredAfterExpiration())
    }

    // MARK: - BreakTimerView's order, end to end

    /// testAX5BreakEndActionIsOnScreenWithoutScrolling: a break recovered on
    /// a cold launch at AX5 reaches 00:00 on screen. It must ring until
    /// stopped (「停止して瓶へ戻る」), not end silently (「瓶へ戻る」).
    func testARecoveredBreakThatEndsOnScreenAfterAColdLaunchRings() {
        var flow = BreakFlow(isRecovery: true)
        flow.appear(sceneIsActive: false)
        let prepare = flow.beginPrepare(remainingAtPrepare: 280)
        flow.sceneBecameActive()
        flow.finishPrepare(prepare)
        flow.finishNotificationScheduling(prepare)

        XCTAssertEqual(flow.tickAtEnd(), .repeating)
    }

    func testARecoveredBreakThatEndsOnScreenRingsWhateverTheRefreshOrder() {
        var flow = BreakFlow(isRecovery: true)
        flow.appear(sceneIsActive: false)
        let prepare = flow.beginPrepare(remainingAtPrepare: 280)
        flow.finishPrepare(prepare)
        flow.finishNotificationScheduling(prepare)
        flow.sceneBecameActive()

        XCTAssertEqual(flow.tickAtEnd(), .repeating)
    }

    func testARecoveredBreakThatAppearsActiveAndEndsOnScreenRings() {
        var flow = BreakFlow(isRecovery: true)
        flow.appear(sceneIsActive: true)
        let prepare = flow.beginPrepare(remainingAtPrepare: 120)
        flow.finishPrepare(prepare)
        flow.finishNotificationScheduling(prepare)

        XCTAssertEqual(flow.tickAtEnd(), .repeating)
    }

    /// The other half of #32's rule: an end that passed while the app was
    /// closed is never re-armed as a loop, even when the view appeared
    /// before the scene was active and the activation resolves it.
    func testABreakThatEndedBeforeTheRelaunchNeverLoops() {
        var flow = BreakFlow(isRecovery: true)
        flow.appear(sceneIsActive: false)
        let prepare = flow.beginPrepare(remainingAtPrepare: 0)
        XCTAssertNil(flow.finishPrepare(prepare), "Never resolved while inactive")
        let cue = flow.sceneBecameActive(secondsSinceEnd: 20)

        XCTAssertEqual(cue, .single)
        XCTAssertEqual(flow.sceneBecameActiveAfterNotification(), Cue.none)
    }

    func testABreakThatEndedBeforeTheRelaunchIsSilentWhenItAppearsActive() {
        var flow = BreakFlow(isRecovery: true)
        flow.appear(sceneIsActive: true)
        let prepare = flow.beginPrepare(remainingAtPrepare: 0)
        XCTAssertEqual(flow.finishPrepare(prepare, secondsSinceEnd: 600), Cue.none)
    }

    func testANewBreakThatEndsOnScreenRings() {
        var flow = BreakFlow(isRecovery: false)
        flow.appear(sceneIsActive: true)
        let prepare = flow.beginPrepare(remainingAtPrepare: 300)
        flow.finishPrepare(prepare)
        flow.finishNotificationScheduling(prepare)
        XCTAssertEqual(flow.tickAtEnd(), .repeating)
    }
}

/// Replays BreakTimerView's decision points with the real gate, recovery
/// state and cue policy. Only the order of calls is simulated.
private struct BreakFlow {
    struct Prepare {
        let token: UInt64
        let remainingAtPrepare: Int
    }

    private var gate = TimerForegroundResolutionGate()
    private var activation: TimerRecoveryActivation
    private var remaining = 1
    private var signalled: TimerCompletionForegroundFeedbackPolicy.Cue?
    private let endedAt = Date(timeIntervalSinceReferenceDate: 90_000)

    init(isRecovery: Bool) {
        activation = TimerRecoveryActivation(isRecovery: isRecovery)
    }

    mutating func appear(sceneIsActive: Bool) {
        gate.observeAppearance(sceneIsActive: sceneIsActive)
    }

    mutating func beginPrepare(remainingAtPrepare: Int) -> Prepare {
        remaining = remainingAtPrepare
        if remainingAtPrepare > 0 { activation.observeRunning() }
        return Prepare(token: gate.generation, remainingAtPrepare: remainingAtPrepare)
    }

    /// The end of prepareBreak's permission refresh.
    @discardableResult
    mutating func finishPrepare(
        _ prepare: Prepare,
        secondsSinceEnd: TimeInterval = 0
    ) -> TimerCompletionForegroundFeedbackPolicy.Cue? {
        gate.finishAuthorizationRefresh(startedIn: prepare.token)
        guard prepare.remainingAtPrepare == 0 else { return nil }
        guard gate.authorizationIsCurrent else { return nil }
        return signal(returnedFromBackground: false, secondsSinceEnd: secondsSinceEnd)
    }

    /// refreshNotificationScheduling's refresh, taken in the same
    /// generation as prepareBreak's.
    mutating func finishNotificationScheduling(_ prepare: Prepare) {
        gate.finishAuthorizationRefresh(startedIn: prepare.token)
    }

    /// onChange(.active), its refresh, then
    /// handleActiveSceneAfterAuthorizationRefresh.
    @discardableResult
    mutating func sceneBecameActive(
        secondsSinceEnd: TimeInterval = 0,
        notificationMayHaveDelivered: Bool = false
    ) -> TimerCompletionForegroundFeedbackPolicy.Cue? {
        let token = gate.observeScene(isActive: true)
        guard gate.finishAuthorizationRefresh(startedIn: token) else { return nil }
        guard remaining == 0 else {
            activation.observeRunning()
            return nil
        }
        return signal(
            returnedFromBackground: false,
            secondsSinceEnd: secondsSinceEnd,
            notificationMayHaveDelivered: notificationMayHaveDelivered
        )
    }

    /// The same recovery as `sceneBecameActive`, when the OS notification
    /// may already have announced the end.
    func sceneBecameActiveAfterNotification() -> TimerCompletionForegroundFeedbackPolicy.Cue? {
        var copy = BreakFlow(isRecovery: true)
        copy.appear(sceneIsActive: false)
        let prepare = copy.beginPrepare(remainingAtPrepare: 0)
        copy.finishPrepare(prepare)
        return copy.sceneBecameActive(secondsSinceEnd: 5, notificationMayHaveDelivered: true)
    }

    /// The 0.5 s ticker once the countdown reaches 00:00 on screen.
    mutating func tickAtEnd() -> TimerCompletionForegroundFeedbackPolicy.Cue? {
        remaining = 0
        guard gate.allowsForegroundResolution(scenePhaseIsActive: true) else {
            return nil
        }
        return signal(returnedFromBackground: false, secondsSinceEnd: 0)
    }

    private mutating func signal(
        returnedFromBackground: Bool,
        secondsSinceEnd: TimeInterval,
        notificationMayHaveDelivered: Bool = false
    ) -> TimerCompletionForegroundFeedbackPolicy.Cue? {
        guard signalled == nil else { return nil }
        let cue = TimerCompletionForegroundFeedbackPolicy.cue(
            recoveredAfterExpiration: activation.consumeRecoveredAfterExpiration(),
            returnedFromBackground: returnedFromBackground,
            notificationMayHaveDelivered: notificationMayHaveDelivered,
            endedAt: endedAt,
            now: endedAt.addingTimeInterval(secondsSinceEnd)
        )
        signalled = cue
        return cue
    }
}
