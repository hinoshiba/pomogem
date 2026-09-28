import XCTest
@testable import PomoGem

/// A focus or break that reaches its end with the app on screen rings until
/// stopped. Only an end that had already passed when the timer was recovered
/// is marked once or shown silently.
///
/// Both timer views ask `TimerForegroundResolution` at every decision point.
/// The flows at the end of this file drive it in the orders FocusView and
/// BreakTimerView see scene phases and permission refreshes, including the
/// cold-launch order that left a recovered break silent. They cannot pin the
/// views' wiring: which decision each call site asks, and each view's own
/// "resolve once" guard. Only these UI tests pin that, and CI does not run
/// them (each takes several minutes):
/// - TimerOrientationUITests.testAX5BreakEndActionIsOnScreenWithoutScrolling
/// - RuntimeFlowAuditUITests.testARecoveredFocusThatEndsOnScreenRingsUntilStopped
/// - RuntimeFlowAuditUITests.testRelaunchAfterTheBreakEndDoesNotStartTheAlarm
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

    // MARK: - Decisions

    func testAnEndThatWaitsKeepsTheRecoveryAnswerForTheDecisionThatResolvesIt() {
        var resolution = TimerForegroundResolution(isRecovery: true)
        resolution.observeAppearance(sceneIsActive: false)
        resolution.finishAuthorizationRefresh(startedIn: resolution.generation)
        XCTAssertEqual(
            resolution.prepared(isElapsed: true),
            .wait,
            "Never resolved while inactive: the OS notification is still pending"
        )

        let activation = resolution.observeScene(isActive: true)
        XCTAssertTrue(resolution.finishAuthorizationRefresh(startedIn: activation))
        XCTAssertEqual(
            resolution.activated(isElapsed: true, isSchedulingNotification: true),
            .wait,
            "Whether the notification may have been delivered is known only after the add"
        )
        XCTAssertEqual(
            resolution.tick(
                isElapsed: true,
                scenePhaseIsActive: true,
                isSchedulingNotification: false
            ),
            .resolve(recoveredAfterExpiration: true)
        )
        XCTAssertEqual(
            resolution.tick(
                isElapsed: true,
                scenePhaseIsActive: true,
                isSchedulingNotification: false
            ),
            .resolve(recoveredAfterExpiration: false),
            "Answered once: the view's own guard drops any later resolution"
        )
    }

    func testARecoveredTimerFoundRunningAfterItsFirstRefreshEndsLive() {
        var resolution = TimerForegroundResolution(isRecovery: true)
        resolution.observeAppearance(sceneIsActive: true)
        resolution.finishAuthorizationRefresh(startedIn: resolution.generation)
        XCTAssertEqual(resolution.prepared(isElapsed: false), .running)
        XCTAssertEqual(
            resolution.tick(
                isElapsed: true,
                scenePhaseIsActive: true,
                isSchedulingNotification: false
            ),
            .resolve(recoveredAfterExpiration: false)
        )
    }

    func testARecoveredTimerFoundRunningOnActivationEndsLive() {
        var resolution = TimerForegroundResolution(isRecovery: true)
        resolution.observeAppearance(sceneIsActive: false)
        let activation = resolution.observeScene(isActive: true)
        resolution.finishAuthorizationRefresh(startedIn: activation)
        XCTAssertEqual(
            resolution.activated(isElapsed: false, isSchedulingNotification: false),
            .running
        )
        XCTAssertEqual(
            resolution.tick(
                isElapsed: true,
                scenePhaseIsActive: true,
                isSchedulingNotification: false
            ),
            .resolve(recoveredAfterExpiration: false)
        )
    }

    func testTheTickerNeverResolvesWithoutAFreshActivePhaseAndPermission() {
        var resolution = TimerForegroundResolution(isRecovery: false)
        resolution.observeAppearance(sceneIsActive: true)
        XCTAssertEqual(
            resolution.tick(
                isElapsed: true,
                scenePhaseIsActive: true,
                isSchedulingNotification: false
            ),
            .wait,
            "Permission must be re-read in this activation first"
        )
        resolution.finishAuthorizationRefresh(startedIn: resolution.generation)
        XCTAssertEqual(
            resolution.tick(
                isElapsed: true,
                scenePhaseIsActive: false,
                isSchedulingNotification: false
            ),
            .wait
        )
        XCTAssertEqual(
            resolution.tick(
                isElapsed: false,
                scenePhaseIsActive: true,
                isSchedulingNotification: false
            ),
            .running
        )
        XCTAssertEqual(
            resolution.tick(
                isElapsed: true,
                scenePhaseIsActive: true,
                isSchedulingNotification: true
            ),
            .wait
        )
    }

    func testAnActivationDecidesNothingBeforeItsRefreshOpensTheGate() {
        var resolution = TimerForegroundResolution(isRecovery: true)
        resolution.observeScene(isActive: true)
        XCTAssertEqual(
            resolution.activated(isElapsed: false, isSchedulingNotification: false),
            .wait
        )
        let activation = resolution.observeScene(isActive: true)
        resolution.finishAuthorizationRefresh(startedIn: activation)
        XCTAssertEqual(
            resolution.activated(isElapsed: true, isSchedulingNotification: false),
            .resolve(recoveredAfterExpiration: true),
            "The earlier decision must not have used up the recovery answer"
        )
    }

    // MARK: - BreakTimerView's order

    /// testAX5BreakEndActionIsOnScreenWithoutScrolling: a break recovered on
    /// a cold launch at AX5 reaches 00:00 on screen. It must ring until
    /// stopped (「停止して瓶へ戻る」), not end silently (「瓶へ戻る」).
    func testARecoveredBreakThatEndsOnScreenAfterAColdLaunchRings() {
        var flow = BreakFlow(isRecovery: true)
        flow.appear(sceneIsActive: false)
        let prepare = flow.beginPrepare(remainingAtPrepare: 280)
        XCTAssertNil(flow.sceneBecameActive())
        XCTAssertNil(flow.finishPrepare(prepare))
        let scheduling = flow.beginNotificationScheduling()
        flow.finishNotificationScheduling(scheduling)

        XCTAssertEqual(flow.tickAtEnd(), .repeating)
    }

    func testARecoveredBreakThatEndsOnScreenRingsWhateverTheRefreshOrder() {
        var flow = BreakFlow(isRecovery: true)
        flow.appear(sceneIsActive: false)
        let prepare = flow.beginPrepare(remainingAtPrepare: 280)
        XCTAssertNil(flow.finishPrepare(prepare))
        let scheduling = flow.beginNotificationScheduling()
        XCTAssertNil(flow.sceneBecameActive())
        flow.finishNotificationScheduling(scheduling)

        XCTAssertEqual(flow.tickAtEnd(), .repeating)
    }

    func testARecoveredBreakThatAppearsActiveAndEndsOnScreenRings() {
        var flow = BreakFlow(isRecovery: true)
        flow.appear(sceneIsActive: true)
        let prepare = flow.beginPrepare(remainingAtPrepare: 120)
        XCTAssertNil(flow.finishPrepare(prepare))
        let scheduling = flow.beginNotificationScheduling()
        flow.finishNotificationScheduling(scheduling)

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

        XCTAssertEqual(flow.sceneBecameActive(secondsSinceEnd: 20), .single)
        XCTAssertNil(flow.tickAtEnd(), "The break end is signalled once")
    }

    func testABreakThatEndedBeforeTheRelaunchIsSilentWhenTheNotificationMayHaveArrived() {
        var flow = BreakFlow(isRecovery: true)
        flow.appear(sceneIsActive: false)
        let prepare = flow.beginPrepare(remainingAtPrepare: 0)
        XCTAssertNil(flow.finishPrepare(prepare))

        XCTAssertEqual(
            flow.sceneBecameActive(
                secondsSinceEnd: 5,
                notificationMayHaveDelivered: true
            ),
            Cue.none
        )
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
        XCTAssertNil(flow.finishPrepare(prepare))
        let scheduling = flow.beginNotificationScheduling()
        flow.finishNotificationScheduling(scheduling)
        XCTAssertEqual(flow.tickAtEnd(), .repeating)
    }

    // MARK: - FocusView's order

    /// testARecoveredFocusThatEndsOnScreenRingsUntilStopped: a focus
    /// recovered on a cold launch reaches 00:00 on screen and must ring.
    func testARecoveredFocusThatEndsOnScreenAfterAColdLaunchRings() {
        var flow = FocusFlow(isRecovery: true, remaining: 4)
        let activation = flow.appear(sceneIsActive: false)
        XCTAssertNil(flow.returnToScene())
        XCTAssertNil(flow.finishActivation(activation))

        flow.reachEnd()
        XCTAssertEqual(flow.tick(), .repeating)
    }

    func testARecoveredFocusThatEndsOnScreenRingsWhenItsActivationFinishesFirst() {
        var flow = FocusFlow(isRecovery: true, remaining: 4)
        let activation = flow.appear(sceneIsActive: false)
        XCTAssertNil(flow.finishActivation(activation))
        XCTAssertNil(flow.returnToScene())

        flow.reachEnd()
        XCTAssertEqual(flow.tick(), .repeating)
    }

    func testAFocusThatEndedWhileTheAppWasClosedIsMarkedOnceOnRelaunch() {
        var flow = FocusFlow(isRecovery: true, remaining: 0)
        let activation = flow.appear(sceneIsActive: false)
        XCTAssertNil(flow.finishActivation(activation), "Never resolved while inactive")

        XCTAssertEqual(flow.returnToScene(secondsSinceEnd: 20), .single)
        XCTAssertNil(flow.tick(), "The engine completes once")
    }

    func testAFocusThatEndedWhileClosedIsSilentWhenTheNotificationMayHaveArrived() {
        var flow = FocusFlow(isRecovery: true, remaining: 0)
        let activation = flow.appear(sceneIsActive: false)
        XCTAssertNil(flow.finishActivation(activation))

        XCTAssertEqual(
            flow.returnToScene(secondsSinceEnd: 5, notificationMayHaveDelivered: true),
            Cue.none
        )
    }

    func testAFocusRecoveredLongAfterItsEndIsSilent() {
        var flow = FocusFlow(isRecovery: true, remaining: 0)
        let activation = flow.appear(sceneIsActive: true)
        XCTAssertEqual(
            flow.finishActivation(activation, secondsSinceEnd: 600),
            Cue.none
        )
    }

    func testANewFocusThatEndsOnScreenRings() {
        var flow = FocusFlow(isRecovery: false, remaining: 1_500)
        let activation = flow.appear(sceneIsActive: true)
        XCTAssertNil(flow.finishActivation(activation))

        flow.reachEnd()
        XCTAssertEqual(flow.tick(), .repeating)
    }

    func testAFocusThatEndsInTheBackgroundIsMarkedOnceOnReturn() {
        var flow = FocusFlow(isRecovery: false, remaining: 1_500)
        let activation = flow.appear(sceneIsActive: true)
        XCTAssertNil(flow.finishActivation(activation))
        flow.leaveScene(toBackground: true)

        flow.reachEnd()
        XCTAssertNil(flow.tick(), "Never resolved in the background")
        XCTAssertEqual(flow.returnToScene(secondsSinceEnd: 10), .single)
    }

    func testAFocusThatEndsDuringAnInactiveInterruptionStillRings() {
        var flow = FocusFlow(isRecovery: false, remaining: 1_500)
        let activation = flow.appear(sceneIsActive: true)
        XCTAssertNil(flow.finishActivation(activation))
        flow.leaveScene(toBackground: false)

        flow.reachEnd()
        XCTAssertNil(flow.tick())
        XCTAssertEqual(flow.returnToScene(secondsSinceEnd: 3), .repeating)
    }

    func testARecoveredEndWaitingForANotificationAddIsStillARecovery() {
        var flow = FocusFlow(isRecovery: true, remaining: 0)
        let activation = flow.appear(sceneIsActive: false)
        XCTAssertNil(flow.finishActivation(activation))
        flow.isSchedulingNotification = true
        XCTAssertNil(flow.returnToScene(secondsSinceEnd: 2))

        flow.isSchedulingNotification = false
        XCTAssertEqual(flow.tick(secondsSinceEnd: 3), .single)
    }
}

/// BreakTimerView's calls into `TimerForegroundResolution`, in the view's
/// order. As in the view, the decision answers the recovery question before
/// `signalBreakCompletionIfNeeded` checks `didSignalCompletion`.
private struct BreakFlow {
    typealias Cue = TimerCompletionForegroundFeedbackPolicy.Cue

    struct Refresh {
        let generation: UInt64
    }

    private var resolution: TimerForegroundResolution
    private var remaining = 1
    private var didSignalCompletion = false
    private let endedAt = Date(timeIntervalSinceReferenceDate: 90_000)

    init(isRecovery: Bool) {
        resolution = TimerForegroundResolution(isRecovery: isRecovery)
    }

    /// prepareBreak, before its first suspension.
    mutating func appear(sceneIsActive: Bool) {
        resolution.observeAppearance(sceneIsActive: sceneIsActive)
    }

    /// prepareBreak reads its end date, then starts its permission refresh.
    mutating func beginPrepare(remainingAtPrepare: Int) -> Refresh {
        remaining = remainingAtPrepare
        if remainingAtPrepare > 0 { resolution.observeRunning() }
        return Refresh(generation: resolution.generation)
    }

    /// prepareBreak's refresh finishes. A running break goes on to
    /// refreshNotificationScheduling.
    mutating func finishPrepare(
        _ refresh: Refresh,
        secondsSinceEnd: TimeInterval = 0
    ) -> Cue? {
        resolution.finishAuthorizationRefresh(startedIn: refresh.generation)
        guard case let .resolve(recoveredAfterExpiration) =
                resolution.prepared(isElapsed: remaining == 0) else { return nil }
        return signal(
            recoveredAfterExpiration: recoveredAfterExpiration,
            returnedFromBackground: false,
            secondsSinceEnd: secondsSinceEnd
        )
    }

    /// refreshNotificationScheduling starts its own permission refresh.
    func beginNotificationScheduling() -> Refresh {
        Refresh(generation: resolution.generation)
    }

    mutating func finishNotificationScheduling(_ refresh: Refresh) {
        guard !didSignalCompletion else { return }
        resolution.finishAuthorizationRefresh(startedIn: refresh.generation)
    }

    /// onChange(.active), its refresh, then
    /// handleActiveSceneAfterAuthorizationRefresh.
    mutating func sceneBecameActive(
        secondsSinceEnd: TimeInterval = 0,
        notificationMayHaveDelivered: Bool = false
    ) -> Cue? {
        let generation = resolution.observeScene(isActive: true)
        guard !didSignalCompletion,
              resolution.finishAuthorizationRefresh(startedIn: generation)
        else { return nil }
        guard case let .resolve(recoveredAfterExpiration) = resolution.activated(
            isElapsed: remaining == 0,
            isSchedulingNotification: false
        ) else { return nil }
        return signal(
            recoveredAfterExpiration: recoveredAfterExpiration,
            returnedFromBackground: false,
            secondsSinceEnd: secondsSinceEnd,
            notificationMayHaveDelivered: notificationMayHaveDelivered
        )
    }

    /// The 0.5 s ticker once the countdown reaches 00:00 on screen.
    mutating func tickAtEnd() -> Cue? {
        remaining = 0
        guard case let .resolve(recoveredAfterExpiration) = resolution.tick(
            isElapsed: true,
            scenePhaseIsActive: true,
            isSchedulingNotification: false
        ) else { return nil }
        return signal(
            recoveredAfterExpiration: recoveredAfterExpiration,
            returnedFromBackground: false,
            secondsSinceEnd: 0
        )
    }

    private mutating func signal(
        recoveredAfterExpiration: Bool,
        returnedFromBackground: Bool,
        secondsSinceEnd: TimeInterval,
        notificationMayHaveDelivered: Bool = false
    ) -> Cue? {
        let cue = TimerCompletionForegroundFeedbackPolicy.cue(
            recoveredAfterExpiration: recoveredAfterExpiration,
            returnedFromBackground: returnedFromBackground,
            notificationMayHaveDelivered: notificationMayHaveDelivered,
            endedAt: endedAt,
            now: endedAt.addingTimeInterval(secondsSinceEnd)
        )
        guard !didSignalCompletion else { return nil }
        didSignalCompletion = true
        return cue
    }
}

/// FocusView's calls into `TimerForegroundResolution`, in the view's order.
/// The engine completes a focus once, which stands in for the view's guard.
private struct FocusFlow {
    typealias Cue = TimerCompletionForegroundFeedbackPolicy.Cue

    struct Activation {
        let generation: UInt64
    }

    var isSchedulingNotification = false
    private var resolution: TimerForegroundResolution
    private var remaining: Int
    private var sceneIsActive = false
    private var didEnterBackgroundSinceLastActive = false
    private var isCompleted = false
    private let endedAt = Date(timeIntervalSinceReferenceDate: 90_000)

    init(isRecovery: Bool, remaining: Int) {
        resolution = TimerForegroundResolution(isRecovery: isRecovery)
        self.remaining = remaining
    }

    /// beginActivation, before its first suspension; activate then starts
    /// its permission refresh.
    mutating func appear(sceneIsActive: Bool) -> Activation {
        self.sceneIsActive = sceneIsActive
        resolution.observeAppearance(sceneIsActive: sceneIsActive)
        return Activation(generation: resolution.generation)
    }

    /// activate's refresh finishes, and it reads the recovered timer.
    mutating func finishActivation(
        _ activation: Activation,
        secondsSinceEnd: TimeInterval = 0
    ) -> Cue? {
        resolution.finishAuthorizationRefresh(startedIn: activation.generation)
        guard case let .resolve(recoveredAfterExpiration) =
                resolution.prepared(isElapsed: remaining == 0) else { return nil }
        return complete(
            recoveredAfterExpiration: recoveredAfterExpiration,
            returnedFromBackground: false,
            secondsSinceEnd: secondsSinceEnd
        )
    }

    /// onChange(of: scenePhase) to inactive or background.
    mutating func leaveScene(toBackground: Bool) {
        sceneIsActive = false
        resolution.observeScene(isActive: false)
        if toBackground { didEnterBackgroundSinceLastActive = true }
    }

    /// onChange(.active), its refresh, then handleScenePhase(to: .active).
    mutating func returnToScene(
        secondsSinceEnd: TimeInterval = 0,
        notificationMayHaveDelivered: Bool = false
    ) -> Cue? {
        sceneIsActive = true
        let generation = resolution.observeScene(isActive: true)
        guard resolution.finishAuthorizationRefresh(startedIn: generation) else {
            return nil
        }
        let decision = resolution.activated(
            isElapsed: remaining == 0,
            isSchedulingNotification: isSchedulingNotification
        )
        // The view keeps the background-return flag only while it waits.
        guard decision != .wait else { return nil }
        let returnedFromBackground = didEnterBackgroundSinceLastActive
        didEnterBackgroundSinceLastActive = false
        guard case let .resolve(recoveredAfterExpiration) = decision else {
            return nil
        }
        return complete(
            recoveredAfterExpiration: recoveredAfterExpiration,
            returnedFromBackground: returnedFromBackground,
            secondsSinceEnd: secondsSinceEnd,
            notificationMayHaveDelivered: notificationMayHaveDelivered
        )
    }

    mutating func reachEnd() {
        remaining = 0
    }

    /// The 0.5 s ticker, with the phase it is handed.
    mutating func tick(secondsSinceEnd: TimeInterval = 0) -> Cue? {
        guard case let .resolve(recoveredAfterExpiration) = resolution.tick(
            isElapsed: remaining == 0,
            scenePhaseIsActive: sceneIsActive,
            isSchedulingNotification: isSchedulingNotification
        ) else { return nil }
        let returnedFromBackground = didEnterBackgroundSinceLastActive
        didEnterBackgroundSinceLastActive = false
        return complete(
            recoveredAfterExpiration: recoveredAfterExpiration,
            returnedFromBackground: returnedFromBackground,
            secondsSinceEnd: secondsSinceEnd
        )
    }

    private mutating func complete(
        recoveredAfterExpiration: Bool,
        returnedFromBackground: Bool,
        secondsSinceEnd: TimeInterval,
        notificationMayHaveDelivered: Bool = false
    ) -> Cue? {
        let cue = TimerCompletionForegroundFeedbackPolicy.cue(
            recoveredAfterExpiration: recoveredAfterExpiration,
            returnedFromBackground: returnedFromBackground,
            notificationMayHaveDelivered: notificationMayHaveDelivered,
            endedAt: endedAt,
            now: endedAt.addingTimeInterval(secondsSinceEnd)
        )
        guard !isCompleted else { return nil }
        isCompleted = true
        return cue
    }
}
