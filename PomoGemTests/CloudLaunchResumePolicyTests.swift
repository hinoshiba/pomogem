import CloudKit
import SwiftUI
import UIKit
import XCTest
@testable import PomoGem

/// quality-01 / launch-01. The decisions that let an iCloud user come back
/// from a lock or an app switch without losing the running focus: the walls a
/// restored connection clears by itself, and which failures may retire the
/// timer surfaces that still belong to that focus.
final class CloudLaunchResumePolicyTests: XCTestCase {
    // MARK: Automatic online retry

    func testOnlyAnObservedOfflineToOnlineTransitionRetriesFromEitherWall() {
        for wall in [CloudLaunchReconnectWall.offlineRelaunchRequired, .cloudVerificationTimedOut] {
            XCTAssertTrue(CloudOfflineHostPolicy.retriesOnlineAfterReconnect(
                previousIsOffline: true, currentIsOffline: false, hasSession: false, wall: wall))
            // An unknown first observation, a path that stayed online, a path
            // that went offline, and an unresolved one are not reconnects.
            for (previous, current) in [(nil, false), (false, false), (false, true), (true, true),
                                        (true, nil), (nil, nil)] as [(Bool?, Bool?)] {
                XCTAssertFalse(CloudOfflineHostPolicy.retriesOnlineAfterReconnect(
                    previousIsOffline: previous, currentIsOffline: current, hasSession: false, wall: wall),
                    "previous=\(String(describing: previous)) current=\(String(describing: current))")
            }
        }
    }

    func testAReconnectNeverRetriesOverAMountedSessionOrAnotherScreen() {
        for wall in [CloudLaunchReconnectWall.offlineRelaunchRequired, .cloudVerificationTimedOut] {
            XCTAssertFalse(CloudOfflineHostPolicy.retriesOnlineAfterReconnect(
                previousIsOffline: true, currentIsOffline: false, hasSession: true, wall: wall),
                "A mounted session has its own reconnect path and is never replaced here")
        }
        // Every other launch screen: a choice, a transfer stop, a failure, a
        // spinner. None of them may start an online launch on a network hint.
        XCTAssertFalse(CloudOfflineHostPolicy.retriesOnlineAfterReconnect(
            previousIsOffline: true, currentIsOffline: false, hasSession: false, wall: nil))
    }

    // MARK: Timer surfaces after a failed launch

    private func verification(_ kind: CloudAccountVerificationFailure.Kind) -> CloudAccountVerificationFailure {
        CloudAccountVerificationFailure(kind: kind, stage: .privateDatabase)
    }

    func testTransportFailuresKeepTheRunningFocusNotificationsAndLiveActivity() {
        let transport: [Error] = [
            CloudLaunchDeadlineError.expired,
            CloudActivityHistoryPreflightError.timedOut,
            CloudActivityHistoryPreflightError.incompleteHistory,
            CloudStorageTransferCloudError.timedOut,
            PersistenceContainerRetirementError.previousContainerStillActive,
            StorageTransferRuntimeError.remoteRecoveryRequired,
            CancellationError(),
        ] + [CloudAccountVerificationFailure.Kind.networkUnavailable, .serviceUnavailable, .timedOut,
             .quota, .temporarilyUnavailable, .identityUnstable, .unknown, .configuration, .permission]
            .flatMap { kind -> [Error] in
                let failure = verification(kind)
                return [failure, AppleAccountBoundaryResolutionError.verification(failure),
                        CloudActivityHistoryPreflightError.cloud(failure),
                        CloudStorageTransferCloudError.cloud(failure)]
            }
        for error in transport {
            XCTAssertFalse(CloudOfflineHostPolicy.retiresExternalTimerState(
                after: error, hasUnresolvedAccountStateMovement: false),
                "\(error) says nothing about who is signed in")
        }
    }

    func testIdentityVerdictsStillRetireEveryTimerSurface() {
        var verdicts: [Error] = [
            AppleAccountBoundaryResolutionError.blocked(.accountMismatch),
            AppleAccountBoundaryResolutionError.blocked(.identityUnavailable),
            AppleAccountBoundaryResolutionError.blocked(.invalidVerifiedIdentity),
            AppleAccountBoundaryResolutionError.blocked(.invalidStoredRegistry),
        ]
        for kind in [CloudAccountVerificationFailure.Kind.noAccount, .restricted] {
            let failure = verification(kind)
            verdicts += [failure, AppleAccountBoundaryResolutionError.verification(failure),
                         CloudActivityHistoryPreflightError.cloud(failure),
                         CloudStorageTransferCloudError.cloud(failure)]
        }
        for error in verdicts {
            XCTAssertTrue(CloudOfflineHostPolicy.retiresExternalTimerState(
                after: error, hasUnresolvedAccountStateMovement: false), "\(error)")
        }
    }

    func testAnUnresolvedAccountMovementRetiresEvenOnATransportFailure() {
        XCTAssertTrue(CloudOfflineHostPolicy.retiresExternalTimerState(
            after: CloudLaunchDeadlineError.expired, hasUnresolvedAccountStateMovement: true))
        XCTAssertTrue(CloudOfflineHostPolicy.retiresExternalTimerState(
            after: verification(.networkUnavailable), hasUnresolvedAccountStateMovement: true))
    }

    // MARK: Account-neutral timer card

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func focusEnvelope(_ mutate: (inout PomodoroEngine) throws -> Void) rethrows -> FocusRecoveryEnvelope {
        var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
        try mutate(&engine)
        return FocusRecoveryEnvelope(engine: engine, subject: nil, clockAnchor: nil,
                                     pendingCompletion: nil, savedAt: start)
    }

    func testARunningFocusShowsItsEndAndBecomesFinishedWhenItPasses() throws {
        let running = try focusEnvelope { try $0.startFocus(isPro: false, now: start) }
        let end = start.addingTimeInterval(25 * 60)
        let status = LaunchTimerStatus.resolve(focus: running, rest: nil, now: start.addingTimeInterval(60))
        XCTAssertEqual(status, .focusRunning(endDate: end))
        XCTAssertEqual(status?.remainingSeconds(at: start.addingTimeInterval(60)), 24 * 60)
        XCTAssertEqual(status?.advanced(to: end), .focusFinished,
                       "A focus that ends while the person waits turns into the finished card")
        XCTAssertEqual(LaunchTimerStatus.resolve(focus: running, rest: nil, now: end), .focusFinished)
    }

    func testAPausedFocusShowsItsFrozenRemainder() throws {
        let paused = try focusEnvelope {
            try $0.startFocus(isPro: false, now: start)
            try $0.pause(at: start.addingTimeInterval(5 * 60))
        }
        let status = LaunchTimerStatus.resolve(focus: paused, rest: nil, now: start.addingTimeInterval(3_600))
        XCTAssertEqual(status, .focusPaused(remainingSeconds: 20 * 60))
        XCTAssertEqual(status?.advanced(to: start.addingTimeInterval(7_200)), status)
    }

    func testAWaitingCompletionIsFinishedAndABreakCountsDownThenDisappears() throws {
        var completed = try focusEnvelope { try $0.startFocus(isPro: false, now: start) }
        let completion = PomodoroCompletion(sessionID: UUID(), startedAt: start,
            endedAt: start.addingTimeInterval(1_500), observedAt: start.addingTimeInterval(1_500),
            duration: .twentyFiveMinutes, seconds: 1_500, grams: 250, source: .timer)
        completed.pendingCompletion = completion
        XCTAssertEqual(LaunchTimerStatus.resolve(focus: completed, rest: nil, now: start), .focusFinished)

        let breakEnd = start.addingTimeInterval(5 * 60)
        let rest = BreakRecoveryEnvelope(id: UUID(), minutes: 5, endDate: breakEnd)
        let status = LaunchTimerStatus.resolve(focus: nil, rest: rest, now: start)
        XCTAssertEqual(status, .breakRunning(endDate: breakEnd))
        XCTAssertNil(status?.advanced(to: breakEnd), "An ended break is not worth a card")
        XCTAssertNil(LaunchTimerStatus.resolve(focus: nil, rest: nil, now: start))
    }

    func testTheCardAppearsOnlyOnTheWaitingScreensOfTheClosedSession() {
        for screen in [LaunchTimerStatusPolicy.Screen.preparing, .offlineWall, .verificationTimedOut] {
            XCTAssertTrue(LaunchTimerStatusPolicy.showsTimerStatus(on: screen,
                hasSuspendedAccountBinding: true, hasUnresolvedAccountStateMovement: false,
                transferIsInProgress: false, requiresRelaunch: false))
            XCTAssertFalse(LaunchTimerStatusPolicy.showsTimerStatus(on: screen,
                hasSuspendedAccountBinding: false, hasUnresolvedAccountStateMovement: false,
                transferIsInProgress: false, requiresRelaunch: false),
                "An identity verdict clears the binding and must remove the card with the Live Activity")
            XCTAssertFalse(LaunchTimerStatusPolicy.showsTimerStatus(on: screen,
                hasSuspendedAccountBinding: true, hasUnresolvedAccountStateMovement: true,
                transferIsInProgress: false, requiresRelaunch: false),
                "A possible account change never shows the previous account's timer")
            XCTAssertFalse(LaunchTimerStatusPolicy.showsTimerStatus(on: screen,
                hasSuspendedAccountBinding: true, hasUnresolvedAccountStateMovement: false,
                transferIsInProgress: true, requiresRelaunch: false))
            XCTAssertFalse(LaunchTimerStatusPolicy.showsTimerStatus(on: screen,
                hasSuspendedAccountBinding: true, hasUnresolvedAccountStateMovement: false,
                transferIsInProgress: false, requiresRelaunch: true))
        }
        XCTAssertFalse(LaunchTimerStatusPolicy.showsTimerStatus(on: .other,
            hasSuspendedAccountBinding: true, hasUnresolvedAccountStateMovement: false,
            transferIsInProgress: false, requiresRelaunch: false))
    }

    func testPeekingANamespaceTimerReadsWithoutChangingAnything() throws {
        let suite = "CloudLaunchResumePolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let namespace = AccountDataNamespace()
        let other = AccountDataNamespace()
        let running = try focusEnvelope { try $0.startFocus(isPro: false, now: start) }
        let focusKey = AccountScopedLocalState.defaultsKey(base: "focus.persisted-engine", namespace: namespace)
        defaults.set(try JSONEncoder().encode(running), forKey: focusKey)
        // A corrupt break next to it must be ignored, and never cleared: the
        // account behind this namespace has not been verified in this launch.
        let breakKey = AccountScopedLocalState.defaultsKey(base: "break.persisted-session", namespace: namespace)
        defaults.set(Data("not json".utf8), forKey: breakKey)
        let before = defaults.dictionaryRepresentation().filter { $0.key.contains(".account.") }

        let peeked = FocusPersistence.peekTimerEnvelopes(namespace: namespace, defaults: defaults, at: start)
        XCTAssertEqual(peeked.focus, running)
        XCTAssertNil(peeked.rest)
        XCTAssertNil(FocusPersistence.peekTimerEnvelopes(namespace: other, defaults: defaults, at: start).focus,
                     "Another namespace's timer is never read")
        let after = defaults.dictionaryRepresentation().filter { $0.key.contains(".account.") }
        XCTAssertEqual(NSDictionary(dictionary: before), NSDictionary(dictionary: after))
    }

    // MARK: Background grace — scene policy

    private func sceneAction(_ phase: ScenePhase, hasSession: Bool = true, isPreparing: Bool = false,
                             quiescing: Bool = false, cloud: Bool = true,
                             offline: Bool = false) -> PersistenceSceneTransitionAction {
        PersistenceLaunchScenePolicy.action(phase: phase, hasSession: hasSession, isPreparing: isPreparing,
            isQuiescingAccountChange: quiescing, usesCloudAccountBoundary: cloud,
            isCloudOfflineSession: offline)
    }

    func testOnlyAPublishedOnlineSessionIsHeldForTheGrace() {
        XCTAssertEqual(sceneAction(.background), .deferCloudRetirement)
        XCTAssertEqual(sceneAction(.inactive), .none, "A system panel keeps the session as before")
        XCTAssertEqual(sceneAction(.background, hasSession: false, isPreparing: true), .retireCloudSession,
                       "An unpublished launch loses its authorization at once")
        XCTAssertEqual(sceneAction(.background, isPreparing: true), .retireCloudSession,
                       "A session that is being replaced is never held")
        XCTAssertEqual(sceneAction(.background, offline: true), .none,
                       "A .none session has no CloudKit transport and keeps its Root as before")
        XCTAssertEqual(sceneAction(.background, quiescing: true), .none,
                       "An account quiescence already owns the retirement")
        XCTAssertEqual(sceneAction(.background, cloud: false), .none, "Local-only is not an account boundary")
        XCTAssertEqual(sceneAction(.active), .none, "Returning within the grace keeps the same session")
    }

    // MARK: Background grace — timing

    func testTheGraceIsFifteenSecondsAndAlwaysLeavesTimeToRetire() {
        typealias Policy = CloudBackgroundGracePolicy
        XCTAssertEqual(Policy.start(backgroundTaskGranted: false, backgroundTimeRemaining: 30), .retireNow,
                       "No background task means no hold")
        XCTAssertEqual(Policy.start(backgroundTaskGranted: true, backgroundTimeRemaining: 30), .retireAfter(15))
        XCTAssertEqual(Policy.start(backgroundTaskGranted: true, backgroundTimeRemaining: 12), .retireAfter(7),
                       "Clamped to the remaining background time minus the retirement margin")
        XCTAssertEqual(Policy.start(backgroundTaskGranted: true, backgroundTimeRemaining: 6), .retireAfter(1))
        for tooShort in [5.9, 5, 1, 0, -1] {
            XCTAssertEqual(Policy.start(backgroundTaskGranted: true, backgroundTimeRemaining: tooShort), .retireNow,
                           "\(tooShort) s cannot hold a session and still retire it safely")
        }
        XCTAssertEqual(Policy.start(backgroundTaskGranted: true, backgroundTimeRemaining: .nan), .retireNow)
        for unbounded in [TimeInterval.greatestFiniteMagnitude, .infinity, 600, 3_600] {
            XCTAssertEqual(Policy.start(backgroundTaskGranted: true, backgroundTimeRemaining: unbounded),
                           .retireAfter(15), "An uncounted background budget is not a long grace")
        }
        XCTAssertTrue(Policy.retiresWhenGraceElapses(sceneIsInBackground: true))
        XCTAssertFalse(Policy.retiresWhenGraceElapses(sceneIsInBackground: false),
                       "A scene that came back to the foreground is not about to be suspended")
    }

    // MARK: Background grace — retained-session recheck

    func testARetainedSessionClosesOnlyOnAnIdentityVerdict() {
        typealias Policy = CloudBackgroundGracePolicy
        let verdicts: [Error] = [
            AppleAccountBoundaryResolutionError.blocked(.accountMismatch),
            AppleAccountBoundaryResolutionError.blocked(.invalidStoredRegistry),
            AppleAccountBoundaryResolutionError.blocked(.invalidVerifiedIdentity),
            AppleAccountBoundaryResolutionError.verification(verification(.noAccount)),
            AppleAccountBoundaryResolutionError.verification(verification(.restricted)),
        ]
        for error in verdicts {
            XCTAssertEqual(Policy.retainedSessionRecheckReaction(after: error), .quiesce, "\(error)")
        }
        let transport: [Error] = [CancellationError()]
            + [CloudAccountVerificationFailure.Kind.networkUnavailable, .serviceUnavailable, .timedOut,
               .identityUnstable, .temporarilyUnavailable, .unknown, .quota]
                .map { AppleAccountBoundaryResolutionError.verification(verification($0)) }
        for error in transport {
            XCTAssertEqual(Policy.retainedSessionRecheckReaction(after: error), .keepSession,
                           "\(error) must not close a screen the person is using")
        }
    }

    // MARK: Background grace — the real controller

    @MainActor
    private final class GraceHarness {
        var began: [String] = []
        var ended: [UIBackgroundTaskIdentifier] = []
        var expiration: (@MainActor () -> Void)?
        var remaining: TimeInterval = 30
        var grants = true
        var retirements = 0
        var released = true
        var sceneInBackground = true
        /// When set, the controller reads the phase through the same live
        /// tracker the host uses instead of the flag above.
        var livePhase: LiveScenePhase?
        let grace = GraceGate()
        let sleeps = SleepLog()
        private var nextIdentifier = 1

        lazy var controller = CloudBackgroundGraceController(environment: .init(
            beginBackgroundTask: { [unowned self] name, expiration in
                began.append(name)
                guard grants else { return .invalid }
                self.expiration = expiration
                defer { nextIdentifier += 1 }
                return UIBackgroundTaskIdentifier(rawValue: nextIdentifier)
            },
            endBackgroundTask: { [unowned self] in ended.append($0) },
            backgroundTimeRemaining: { [unowned self] in remaining },
            sleep: { [grace, sleeps] seconds in
                sleeps.append(seconds)
                if seconds >= CloudBackgroundGracePolicy.minimumGrace {
                    try await grace.wait()
                } else {
                    try await Task.sleep(for: .milliseconds(1))
                }
            }))

        func begin(sessionID: UUID = UUID()) -> Bool {
            controller.begin(sessionID: sessionID, retire: { [unowned self] in retirements += 1 },
                             isReleased: { [unowned self] in released },
                             isSceneInBackground: { [unowned self] in livePhase?.isBackground ?? sceneInBackground })
        }

        func settle() async {
            for _ in 0..<50 { await Task.yield() }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private final class SleepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [TimeInterval] = []
        func append(_ value: TimeInterval) { lock.withLock { values.append(value) } }
        var graceTicks: Int {
            lock.withLock { values.filter { $0 != CloudBackgroundGracePolicy.releasePollInterval }.count }
        }
    }

    /// Lets a test decide when the grace "elapses" without waiting 15 s.
    private actor GraceGate {
        private var waiters: [CheckedContinuation<Void, Error>] = []
        private var isOpen = false
        func wait() async throws {
            if isOpen { return }
            try await withCheckedThrowingContinuation { waiters.append($0) }
            try Task.checkCancellation()
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    @MainActor
    func testReturningWithinTheGraceKeepsTheSessionAndEndsTheTask() async {
        let harness = GraceHarness()
        XCTAssertTrue(harness.begin())
        XCTAssertTrue(harness.controller.isHoldingSession)
        XCTAssertTrue(harness.controller.holdsBackgroundTask)
        XCTAssertTrue(harness.controller.sceneBecameActive())
        XCTAssertEqual(harness.retirements, 0, "Root, its sheets and the jar stay on screen")
        XCTAssertEqual(harness.ended.count, 1)
        XCTAssertFalse(harness.controller.holdsBackgroundTask)
        await harness.grace.open()
        await harness.settle()
        XCTAssertEqual(harness.retirements, 0, "A cancelled grace never retires later")
        XCTAssertFalse(harness.controller.sceneBecameActive(), "Nothing left to keep")
    }

    @MainActor
    func testAnElapsedGraceRetiresAndEndsTheTaskOnlyAfterRelease() async {
        let harness = GraceHarness()
        harness.released = false
        XCTAssertTrue(harness.begin())
        await harness.grace.open()
        await harness.settle()
        XCTAssertEqual(harness.retirements, 1)
        XCTAssertTrue(harness.ended.isEmpty,
                      "The process may not be suspended while a retired container is still alive")
        XCTAssertTrue(harness.controller.holdsBackgroundTask)
        harness.released = true
        await harness.settle()
        XCTAssertEqual(harness.ended.count, 1)
        XCTAssertFalse(harness.controller.holdsBackgroundTask)
        XCTAssertFalse(harness.controller.sceneBecameActive(),
                       "After the grace the next foreground remounts, as before")
    }

    @MainActor
    func testExpiryRetiresSynchronouslyAndEndsTheTaskAtOnce() async {
        let harness = GraceHarness()
        harness.released = false
        XCTAssertTrue(harness.begin())
        let expire = try? XCTUnwrap(harness.expiration)
        expire?()
        XCTAssertEqual(harness.retirements, 1, "The session is gone before the handler returns")
        XCTAssertEqual(harness.ended.count, 1, "The expiration handler must end the task")
        await harness.grace.open()
        await harness.settle()
        XCTAssertEqual(harness.retirements, 1)
        XCTAssertEqual(harness.ended.count, 1)
    }

    @MainActor
    func testNoBackgroundTimeRetiresImmediately() async {
        for (grants, remaining) in [(false, 30.0), (true, 4.0)] {
            let harness = GraceHarness()
            harness.grants = grants
            harness.remaining = remaining
            XCTAssertFalse(harness.begin())
            XCTAssertEqual(harness.retirements, 1)
            XCTAssertFalse(harness.controller.isHoldingSession)
            await harness.settle()
            XCTAssertEqual(harness.ended.count, grants ? 1 : 0, "A granted task still ends after release")
        }
    }

    @MainActor
    func testAnAccountChangeDuringTheGraceEndsItWithoutASecondRetirement() async {
        let harness = GraceHarness()
        harness.released = false
        XCTAssertTrue(harness.begin())
        // CKAccountChanged, a storage transfer or deletion retires the session
        // through the host's own path; the controller must not retire again,
        // and must keep the task until that retirement released its stores.
        harness.controller.sessionRetiredElsewhere()
        XCTAssertFalse(harness.controller.isHoldingSession)
        await harness.grace.open()
        await harness.settle()
        XCTAssertEqual(harness.retirements, 0)
        XCTAssertTrue(harness.ended.isEmpty)
        harness.released = true
        await harness.settle()
        XCTAssertEqual(harness.ended.count, 1)
        XCTAssertFalse(harness.controller.sceneBecameActive())
    }

    @MainActor
    func testAGraceThatEndsInTheForegroundDoesNotRetire() async {
        let harness = GraceHarness()
        XCTAssertTrue(harness.begin())
        harness.sceneInBackground = false
        await harness.grace.open()
        await harness.settle()
        XCTAssertEqual(harness.retirements, 0, "Behind Notification Center the app is not about to be suspended")
        XCTAssertEqual(harness.ended.count, 1)
    }

    /// Review of PR #40: the host's closure read `@Environment(\.scenePhase)`,
    /// a snapshot taken by the `.background` handler, so it always said
    /// "background". Through the live tracker, a grace that ends while the
    /// scene is inactive keeps the session — and the next `.active` still
    /// rechecks the account.
    @MainActor
    func testAGraceThatEndsWhileInactiveKeepsTheSessionAndStillRechecks() async {
        let harness = GraceHarness()
        let phase = LiveScenePhase(.background)
        harness.livePhase = phase
        let id = UUID()
        XCTAssertTrue(harness.begin(sessionID: id))
        phase.update(.inactive)
        await harness.grace.open()
        await harness.settle()
        XCTAssertEqual(harness.retirements, 0, "Root is not torn down in front of the person")
        XCTAssertEqual(harness.ended.count, 1, "No background task is held in the foreground")
        XCTAssertTrue(harness.controller.awaitsRecheck)
        XCTAssertTrue(harness.controller.sceneBecameActive(), "The identity recheck still runs on .active")
        XCTAssertFalse(harness.controller.sceneBecameActive())

        // Inactive, then back to the background without ever being active:
        // a new hold with its own task and grace.
        let again = GraceHarness()
        let againPhase = LiveScenePhase(.background)
        again.livePhase = againPhase
        XCTAssertTrue(again.begin(sessionID: id))
        againPhase.update(.inactive)
        await again.grace.open()
        await again.settle()
        againPhase.update(.background)
        XCTAssertTrue(again.begin(sessionID: id))
        XCTAssertEqual(again.began.count, 2, "A session kept after its grace is held again, never left mounted")
        XCTAssertTrue(again.controller.holdsBackgroundTask)
        await again.settle()
        XCTAssertEqual(again.retirements, 1, "The second grace (its gate already open) retires in the background")
    }

    @MainActor
    func testTheLivePhaseIsReadWhenTheClosureRunsNotWhenItWasMade() {
        let phase = LiveScenePhase(.background)
        let isBackground: @MainActor () -> Bool = { [phase] in phase.isBackground }
        XCTAssertTrue(isBackground())
        phase.update(.inactive)
        XCTAssertFalse(isBackground())
        phase.update(.active)
        XCTAssertTrue(phase.isActive)
    }

    /// Review of PR #40: when `.background` still reports an unbounded budget
    /// the grace starts at 15 s. Once iOS counts it, the grace must end
    /// `suspensionMargin` before it runs out instead of leaving the
    /// retirement to the expiration handler.
    @MainActor
    func testTheGraceShortensOnceIOSStartsCountingBackgroundTime() async {
        let harness = GraceHarness()
        harness.released = false
        harness.remaining = .greatestFiniteMagnitude
        XCTAssertTrue(harness.begin())
        harness.remaining = 9
        await harness.grace.open()
        await harness.settle()
        XCTAssertEqual(harness.retirements, 1)
        XCTAssertEqual(harness.sleeps.graceTicks, 5,
                       "One tick at 15 s left, then 9 − 5 s of grace: retired 5 s early, not after 15")
        XCTAssertTrue(harness.ended.isEmpty, "Still waiting for the release, inside the margin")
        harness.released = true
        await harness.settle()
        XCTAssertEqual(harness.ended.count, 1)

        typealias Policy = CloudBackgroundGracePolicy
        XCTAssertEqual(Policy.remainingGrace(14, backgroundTimeRemaining: .greatestFiniteMagnitude), 14)
        XCTAssertEqual(Policy.remainingGrace(14, backgroundTimeRemaining: 9), 4)
        XCTAssertEqual(Policy.remainingGrace(3, backgroundTimeRemaining: 20), 3)
        XCTAssertEqual(Policy.remainingGrace(14, backgroundTimeRemaining: 4), 0)
        XCTAssertEqual(Policy.remainingGrace(14, backgroundTimeRemaining: .nan), 0)
    }

    @MainActor
    func testARepeatedBackgroundForTheSameSessionKeepsOneHold() {
        let harness = GraceHarness()
        let id = UUID()
        XCTAssertTrue(harness.begin(sessionID: id))
        XCTAssertTrue(harness.begin(sessionID: id))
        XCTAssertEqual(harness.began.count, 1, "One grace and one background task per hold")
    }

    // MARK: Navigation after a remount

    @MainActor
    func testTheTabIsRestoredOnlyForTheSameNamespaceAndOnlyOnce() {
        let namespace = AccountDataNamespace()
        let memory = CloudRemountNavigationMemory()
        memory.record(.settings, namespace: namespace)
        XCTAssertEqual(memory.takeRestoredTab(for: namespace), .settings)
        XCTAssertNil(memory.takeRestoredTab(for: namespace), "One use per remount")

        memory.record(.log, namespace: namespace)
        XCTAssertNil(memory.takeRestoredTab(for: AccountDataNamespace()), "Another account never inherits it")
        XCTAssertNil(memory.takeRestoredTab(for: namespace), "A mismatch discards it")

        memory.record(.log, namespace: namespace)
        memory.clear()
        XCTAssertNil(memory.takeRestoredTab(for: namespace))

        memory.record(.settings, namespace: nil)
        XCTAssertNil(memory.takeRestoredTab(for: nil), "Nothing without a namespace to compare")
        XCTAssertNil(CloudRemountNavigationPolicy.restoredTab(saved: .init(namespace: namespace, tab: .log),
                                                              mountedNamespace: nil))
    }

    func testTheOfflineWallLeadsWithTheAutomaticCheckAndNotARelaunch() {
        let message = CloudOfflineSessionError.relaunchRequired.localizedDescription
        XCTAssertTrue(message.contains("自動で確認"))
        XCTAssertTrue(message.contains("記録はこのiPhoneに残っています"))
        XCTAssertFalse(message.contains("先ほどの同期処理"), "No engineering vocabulary on a wall users meet every day")
    }
}
