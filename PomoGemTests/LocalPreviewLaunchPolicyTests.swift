import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import PomoGem

final class LocalPreviewLaunchPolicyTests: XCTestCase {
    func testLaunchWaitsForBothLifecycleSignalsWithoutReportingAnAccountError() {
        for phase in [ScenePhase.inactive, .background, .active] {
            for applicationState in [UIApplication.State.inactive, .background, .active] {
                if phase == .active, applicationState == .active {
                    XCTAssertNoThrow(try PersistenceLaunchScenePolicy.requireActiveAttempt(
                        generationMatches: true, phase: phase, applicationState: applicationState))
                } else {
                    XCTAssertThrowsError(try PersistenceLaunchScenePolicy.requireActiveAttempt(
                        generationMatches: true, phase: phase, applicationState: applicationState)) { error in
                        XCTAssertTrue(error is CancellationError,
                            "Waiting for activation must not become a storage or account failure")
                    }
                }
            }
        }
    }

    func testSupersededLaunchCannotResumeWhenBothLifecycleSignalsAreActive() {
        XCTAssertThrowsError(try PersistenceLaunchScenePolicy.requireActiveAttempt(
            generationMatches: false, phase: .active, applicationState: .active)) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancelledLaunchCannotResumeWhenBothLifecycleSignalsAreActive() async {
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try PersistenceLaunchScenePolicy.requireActiveAttempt(
                    generationMatches: true, phase: .active, applicationState: .active)
                return false
            } catch {
                return error is CancellationError
            }
        }
        let wasCancelled = await task.value
        XCTAssertTrue(wasCancelled)
    }

    func testEitherActivationNotificationOrderResumesDeferredLaunchExactlyOnce() {
        enum ActivationEvent { case scene, application }
        let orders: [[ActivationEvent]] = [[.scene, .application], [.application, .scene]]
        for order in orders {
            var phase = ScenePhase.inactive
            var applicationState = UIApplication.State.inactive
            var isWaitingForActivation = false
            var mountedSessions = 0

            func prepare() {
                isWaitingForActivation = false
                do {
                    try PersistenceLaunchScenePolicy.requireActiveAttempt(
                        generationMatches: true, phase: phase, applicationState: applicationState)
                    mountedSessions += 1
                } catch {
                    XCTAssertTrue(error is CancellationError)
                    isWaitingForActivation = true
                }
            }

            prepare() // SwiftUI may start the first task before either signal.
            XCTAssertTrue(isWaitingForActivation)
            XCTAssertEqual(mountedSessions, 0)
            for event in order + [.application] {
                switch event {
                case .scene:
                    phase = .active
                case .application:
                    applicationState = .active
                    guard PersistenceLaunchScenePolicy.shouldResumeDeferredPreparation(
                        phase: phase, isWaitingForActivation: isWaitingForActivation,
                        hasSession: mountedSessions > 0, isPreparing: false) else {
                        continue
                    }
                }
                let action = PersistenceLaunchScenePolicy.action(
                    phase: phase, hasSession: mountedSessions > 0, isPreparing: false,
                    isQuiescingAccountChange: false, usesCloudAccountBoundary: true)
                if action == .preparePersistence { prepare() }
                if phase != .active || applicationState != .active {
                    XCTAssertEqual(mountedSessions, 0)
                }
            }
            XCTAssertEqual(mountedSessions, 1)
            XCTAssertFalse(isWaitingForActivation)
        }
    }

    func testUIKitActivationOnlyRestartsDeferredUnloadedPreparation() {
        XCTAssertTrue(PersistenceLaunchScenePolicy.shouldResumeDeferredPreparation(
            phase: .active, isWaitingForActivation: true, hasSession: false, isPreparing: false))
        for phase in [ScenePhase.inactive, .background] {
            XCTAssertFalse(PersistenceLaunchScenePolicy.shouldResumeDeferredPreparation(
                phase: phase, isWaitingForActivation: true, hasSession: false, isPreparing: false))
        }
        let settledOrOwned: [(String, Bool, Bool, Bool)] = [
            ("A settled choice or error must await user action", false, false, false),
            ("Running preparation already owns launch", true, false, true),
            ("A published session must stay mounted", true, true, false)
        ]
        for (reason, isWaiting, hasSession, isPreparing) in settledOrOwned {
            XCTAssertFalse(PersistenceLaunchScenePolicy.shouldResumeDeferredPreparation(
                phase: .active, isWaitingForActivation: isWaiting,
                hasSession: hasSession, isPreparing: isPreparing), reason)
        }
    }

    /// Regression for the 2026-09-20 device launch that stopped on
    /// 「保存領域を確認できません」 with the identityUnavailable text and offered no
    /// offline action. The app was launched by XCUITest, so SwiftUI already
    /// reported `.active` while UIKit was still `.inactive`, and the launch
    /// preparation entered the transfer-cleanup check in that frame. That
    /// half-activated frame must stay a lifecycle interruption: it cannot be
    /// reported as a failed Apple Account verification, because the blocked
    /// screen is reached before an offline candidate has been evaluated and
    /// therefore carries no recovery action at all.
    ///
    /// Driven through `DeferredLaunchCancellationRaceHostModel`, which owns the flags the host
    /// owns: reverting the assignment in the host's `catch is CancellationError`
    /// arm, or removing the activation receiver, now fails this test instead of
    /// leaving the suite green.
    func testHalfActivatedLaunchFrameDefersInsteadOfBlockingOnTheAccount() {
        let host = DeferredLaunchCancellationRaceHostModel()
        host.phase = .active              // SwiftUI already reports .active
        host.applicationState = .inactive // UIKit has not posted didBecomeActive

        host.startLaunchAttempt()
        XCTAssertEqual(host.mountedSessions, 0,
            "A pending UIKit activation must not be reported as an unavailable identity")
        XCTAssertEqual(host.screen, .preparing)
        XCTAssertTrue(host.isWaitingForActivation, "The catch must record the wait it depends on")
        XCTAssertFalse(host.isPreparing, "The attempt's defer must release its own flag")

        // No further scene-phase change can arrive: the phase is already
        // active. Only the UIKit notification can restart this launch.
        host.deliverActivationNotification()
        XCTAssertEqual(host.mountedSessions, 1)
        XCTAssertEqual(host.screen, .home)
        XCTAssertFalse(host.isWaitingForActivation)

        // A duplicate activation notification must not start a second launch.
        host.deliverActivationNotification()
        XCTAssertEqual(host.mountedSessions, 1)
    }

    /// The catch used to derive "I am waiting" purely from the lifecycle state
    /// at the moment it ran. `requireCloudMountAuthorization` throws from deep
    /// inside awaited CloudKit work, so the error is observed after actor hops
    /// and the app can already be fully active by then: the flag is computed
    /// as false, `.onChange(of: scenePhase)` has no transition left to report,
    /// and the didBecomeActive receiver has already run against a false flag.
    /// `launchState` then stays `.preparing`, which renders a bare
    /// `ProgressView` with no retry control at all.
    func testACancellationObservedAfterActivationRestartsInsteadOfStranding() {
        let host = DeferredLaunchCancellationRaceHostModel()
        host.phase = .active
        host.applicationState = .inactive
        // The checkpoint inside the cloud mount saw the half-activated frame…
        host.checkpointApplicationState = .inactive
        // …but activation lands while the CancellationError is still
        // propagating, and its receiver finds the waiting flag still false.
        host.activationDuringCancellation = { [unowned host] in
            host.deliverActivationNotification()
        }

        host.startLaunchAttempt()

        XCTAssertEqual(host.mountedSessions, 1,
            "An activation observed before the cancellation is caught must not strand the launch")
        XCTAssertEqual(host.screen, .home)
        XCTAssertFalse(host.isWaitingForActivation)
        XCTAssertFalse(host.isPreparing)
    }

    /// The same ordering while the app is still only half activated keeps the
    /// old behaviour: record the wait, let the real activation restart it.
    func testACancellationObservedWhileStillInactiveStillWaitsForActivation() {
        for applicationState in [UIApplication.State.inactive, .background] {
            let host = DeferredLaunchCancellationRaceHostModel()
            host.phase = .active
            host.applicationState = applicationState

            host.startLaunchAttempt()
            XCTAssertTrue(host.isWaitingForActivation)
            XCTAssertEqual(host.mountedSessions, 0)

            host.deliverActivationNotification()
            XCTAssertEqual(host.mountedSessions, 1)
        }
    }

    /// The deferred resume is gated on `isPreparing`, so a superseded attempt
    /// must never be the one that records the wait: its generation guard fails
    /// first and its successor owns both flags. Pins that a stale attempt
    /// cannot strand an unloaded launch behind a preparation flag it no
    /// longer owns.
    func testSupersededAttemptNeitherRecordsNorConsumesTheDeferredResume() {
        // A superseded attempt is interrupted for the same lifecycle reason,
        // so it cannot be distinguished by its error and must not act on it.
        XCTAssertThrowsError(try PersistenceLaunchScenePolicy.requireActiveAttempt(
            generationMatches: false, phase: .active, applicationState: .inactive)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        // While its successor prepares, the activation notification is ignored;
        // the successor's own defer and catch decide what happens next.
        XCTAssertFalse(PersistenceLaunchScenePolicy.shouldResumeDeferredPreparation(
            phase: .active, isWaitingForActivation: true, hasSession: false, isPreparing: true),
            "A running preparation owns the launch; a stale attempt must not restart it")
        // And the successor is always started by the generation change itself.
        XCTAssertEqual(PersistenceLaunchScenePolicy.action(
            phase: .active, hasSession: false, isPreparing: true,
            isQuiescingAccountChange: false, usesCloudAccountBoundary: true),
            .preparePersistence)
    }

    func testPublishedOfflineRootSurvivesOrdinaryBackgroundAndRevalidatesEveryForeground() {
        for phase in [ScenePhase.inactive, .background, .inactive, .active, .inactive, .background, .active] {
            XCTAssertEqual(PersistenceLaunchScenePolicy.action(
                phase: phase, hasSession: true, isPreparing: false,
                isQuiescingAccountChange: false, usesCloudAccountBoundary: true,
                hasRetiringContainers: true, isCloudOfflineSession: true),
                phase == .active ? .revalidateOfflineSession : .none)
        }
    }

    func testOfflineFlagCannotKeepAnUnpublishedCandidateOrBypassAccountRetirement() {
        for phase in [ScenePhase.inactive, .background] {
            for hasCandidate in [false, true] {
                XCTAssertEqual(PersistenceLaunchScenePolicy.action(
                    phase: phase, hasSession: false, isPreparing: true,
                    isQuiescingAccountChange: false, usesCloudAccountBoundary: true,
                    hasRetiringContainers: hasCandidate, isCloudOfflineSession: true), .retireCloudSession)
            }
        }
        for phase in [ScenePhase.inactive, .background, .active] {
            XCTAssertEqual(PersistenceLaunchScenePolicy.action(
                phase: phase, hasSession: true, isPreparing: false,
                isQuiescingAccountChange: true, usesCloudAccountBoundary: true,
                hasRetiringContainers: true, isCloudOfflineSession: true), .none,
                "An in-progress account retirement owns cleanup; foreground must not reauthorize its Root")
        }
    }

    func testOfflineForegroundStillRevalidatesWhenPersistedModeNoLongerUsesCloudBoundary() {
        XCTAssertEqual(PersistenceLaunchScenePolicy.action(
            phase: .active, hasSession: true, isPreparing: false,
            isQuiescingAccountChange: false, usesCloudAccountBoundary: false,
            isCloudOfflineSession: true), .revalidateOfflineSession,
            "A changed selection cannot make an old offline Root skip its admission check")
    }

    func testOfflineResumeKeepsLocalCopyWithoutNetworkAndRequestsBoundedRetryForOtherPaths() {
        let fixture = OfflineResumeFixture()
        let paths: [(Bool?, PersistenceOfflineResumeAction)] = [
            (true, .keepOffline), (false, .retryConnection), (nil, .retryConnection)
        ]
        for (network, expected) in paths {
            XCTAssertEqual(fixture.action(network: network), expected)
        }
    }

    func testOfflineResumeRejectsMissingObservationsOrChangedSessionBinding() {
        let fixture = OfflineResumeFixture()
        XCTAssertEqual(fixture.action(conditions: nil), .retireSession)
        XCTAssertEqual(PersistenceLaunchScenePolicy.offlineResumeAction(
            sessionNamespace: fixture.binding.namespace, activeBinding: fixture.binding,
            conditions: fixture.conditions(), receipt: nil, revocationWriteFailed: false,
            networkIsOffline: true), .retireSession)
        for namespace in [nil, AccountDataNamespace()] {
            XCTAssertEqual(PersistenceLaunchScenePolicy.offlineResumeAction(
                sessionNamespace: namespace, activeBinding: fixture.binding,
                conditions: fixture.conditions(), receipt: fixture.receipt(), revocationWriteFailed: false,
                networkIsOffline: true), .retireSession)
        }
        let sameNamespaceDifferentAccount = ActiveAccountLocalBinding(namespace: fixture.binding.namespace,
            accountFingerprint: String(repeating: "b", count: 64))!
        for activeBinding in [nil, sameNamespaceDifferentAccount] {
            XCTAssertEqual(PersistenceLaunchScenePolicy.offlineResumeAction(
                sessionNamespace: fixture.binding.namespace, activeBinding: activeBinding,
                conditions: fixture.conditions(), receipt: fixture.receipt(), revocationWriteFailed: false,
                networkIsOffline: false), .retireSession)
        }
        XCTAssertEqual(fixture.action(revocationWriteFailed: true), .retireSession)
    }

    func testOfflineResumeRejectsRevocationChangedSelectionAndPendingWorkBeforeRetry() {
        let fixture = OfflineResumeFixture()
        for revocation in [CloudOfflineRevocationReason.accountChanged, .accountMismatch, .noAccount, .restricted] {
            XCTAssertEqual(fixture.action(receipt: fixture.receipt(revocation: revocation)), .retireSession)
        }
        let local = PersistenceDeploymentSelection.localOnly(namespace: AccountDataNamespace())
        let otherCloud = PersistenceDeploymentSelection.cloud(binding: ActiveAccountLocalBinding(
            namespace: AccountDataNamespace(), accountFingerprint: String(repeating: "b", count: 64))!)
        let invalidConditions = [
            fixture.conditions(selection: .invalid), fixture.conditions(selection: .unselected),
            fixture.conditions(selection: .selected(local)), fixture.conditions(selection: .selected(otherCloud)),
            fixture.conditions(mount: .unrecorded), fixture.conditions(mount: .invalid),
            fixture.conditions(mount: .mounted(otherCloud)), fixture.conditions(complete: false),
            fixture.conditions(pendingTransfer: true), fixture.conditions(pendingIntent: true),
            fixture.conditions(validSchema: false)
        ]
        for conditions in invalidConditions {
            XCTAssertEqual(fixture.action(conditions: conditions), .retireSession)
        }
        let malformed = CloudOfflineAccessReceipt(revisionID: UUID(), binding: fixture.binding,
            origin: .verifiedOnline, isDatasetGenerationKnown: false, datasetGenerationID: nil,
            resetBaseline: nil, wasUsedOffline: true, revocation: nil)
        XCTAssertEqual(fixture.action(receipt: malformed), .retireSession)
    }

    func testFirstActiveSceneRetriesBeforeStorageSelection() {
        XCTAssertEqual(
            PersistenceLaunchScenePolicy.action(
                phase: .active,
                hasSession: false,
                isPreparing: true,
                isQuiescingAccountChange: false,
                usesCloudAccountBoundary: false
            ),
            .preparePersistence
        )
    }

    func testActiveSceneDoesNotReplaceLoadedOrRetiringSession() {
        XCTAssertEqual(
            PersistenceLaunchScenePolicy.action(
                phase: .active,
                hasSession: true,
                isPreparing: false,
                isQuiescingAccountChange: false,
                usesCloudAccountBoundary: true
            ),
            .none
        )
        XCTAssertEqual(
            PersistenceLaunchScenePolicy.action(
                phase: .active,
                hasSession: false,
                isPreparing: false,
                isQuiescingAccountChange: true,
                usesCloudAccountBoundary: true
            ),
            .none
        )
    }

    func testPermissionInterruptionKeepsPublishedSessionWithoutRemountingRoot() {
        // Notification permission panels can hold the scene inactive until
        // the user responds. Neither opening nor dismissing the panel may
        // retire the verified session that owns the onboarding operation.
        for phase in [ScenePhase.inactive, .active, .inactive, .active] {
            XCTAssertEqual(PersistenceLaunchScenePolicy.action(
                phase: phase,
                hasSession: true,
                isPreparing: false,
                isQuiescingAccountChange: false,
                usesCloudAccountBoundary: true,
                hasRetiringContainers: true
            ), .none)
        }
    }

    func testInactivePublishedSessionIsHeldForTheGraceWhenItEntersBackground() {
        func action(_ phase: ScenePhase) -> PersistenceSceneTransitionAction {
            PersistenceLaunchScenePolicy.action(
                phase: phase,
                hasSession: true,
                isPreparing: false,
                isQuiescingAccountChange: false,
                usesCloudAccountBoundary: true,
                hasRetiringContainers: true
            )
        }

        XCTAssertEqual(action(.inactive), .none)
        // quality-01 (owner-approved, 2026-09-24). Moving from a system panel
        // to another app still closes the CloudKit store before the process
        // can be suspended, but through the background grace: the controller
        // retires it after the grace, on expiry, or on any account event.
        XCTAssertEqual(action(.background), .deferCloudRetirement)
    }

    func testUnpublishedCloudMountStillRetiresOnAnyDeactivation() {
        for phase in [ScenePhase.inactive, .background] {
            for hasCandidate in [false, true] {
                XCTAssertEqual(PersistenceLaunchScenePolicy.action(
                    phase: phase,
                    hasSession: false,
                    isPreparing: true,
                    isQuiescingAccountChange: false,
                    usesCloudAccountBoundary: true,
                    hasRetiringContainers: hasCandidate
                ), .retireCloudSession)
            }
        }
    }

    func testOnlyCloudWorkRetiresWhenSceneEntersBackground() {
        XCTAssertEqual(
            PersistenceLaunchScenePolicy.action(
                phase: .background,
                hasSession: false,
                isPreparing: true,
                isQuiescingAccountChange: false,
                usesCloudAccountBoundary: true
            ),
            .retireCloudSession
        )
        XCTAssertEqual(
            PersistenceLaunchScenePolicy.action(
                phase: .background,
                hasSession: true,
                isPreparing: false,
                isQuiescingAccountChange: false,
                usesCloudAccountBoundary: false
            ),
            .none
        )
    }

    func testBackgroundTransitionDoesNotRestartInterruptedMountRetirement() {
        for isPreparing in [false, true] {
            XCTAssertEqual(
                PersistenceLaunchScenePolicy.action(
                    phase: .background,
                    hasSession: false,
                    isPreparing: isPreparing,
                    isQuiescingAccountChange: true,
                    usesCloudAccountBoundary: true
                ),
                .none
            )
        }
    }

    @MainActor
    func testForegroundRecoversWhenContainerReleasesAfterRetirementTimedOut() {
        final class Container {}
        let lifetimes = PersistenceContainerLifetimeTracker<Container>()
        var container: Container? = Container()
        lifetimes.track(container!)
        var budget = PersistenceContainerRetirementPollBudget(maximumPolls: 0)
        XCTAssertEqual(budget.observe(
            isReleased: !lifetimes.hasLiveContainers,
            generationMatches: true
        ), .timedOut)

        func foregroundAction() -> PersistenceSceneTransitionAction {
            PersistenceLaunchScenePolicy.action(
                phase: .active,
                hasSession: false,
                isPreparing: false,
                isQuiescingAccountChange: true,
                usesCloudAccountBoundary: true,
                didTimeOutContainerRetirement: true,
                hasRetiringContainers: lifetimes.hasLiveContainers
            )
        }

        XCTAssertEqual(foregroundAction(), .none)
        // A system callback finishes after the app's two-second retirement
        // budget. Returning to the app should now retry without forcing the
        // user to dismiss a stale storage error manually.
        container = nil
        XCTAssertEqual(foregroundAction(), .resumeAfterContainerRetirement)
    }

    func testForegroundDoesNotBypassOngoingAccountCleanupAfterContainerRelease() {
        for isPreparing in [false, true] {
            XCTAssertEqual(PersistenceLaunchScenePolicy.action(
                phase: .active,
                hasSession: false,
                isPreparing: isPreparing,
                isQuiescingAccountChange: true,
                usesCloudAccountBoundary: true,
                didTimeOutContainerRetirement: false,
                hasRetiringContainers: false
            ), .none)
        }
        XCTAssertEqual(PersistenceLaunchScenePolicy.action(
            phase: .background,
            hasSession: false,
            isPreparing: false,
            isQuiescingAccountChange: true,
            usesCloudAccountBoundary: true,
            didTimeOutContainerRetirement: true,
            hasRetiringContainers: false
        ), .none)
    }

    @MainActor
    func testContainerRetirementWaitsForEveryCandidateAndPublishedSession() throws {
        final class Container {}
        let lifetimes = PersistenceContainerLifetimeTracker<Container>()
        var candidate: Container? = Container()
        var published: Container? = Container()
        lifetimes.track(candidate!)
        lifetimes.track(published!)
        lifetimes.track(published!)

        published = nil
        XCTAssertTrue(lifetimes.hasLiveContainers)
        XCTAssertThrowsError(try lifetimes.requireAllReleased()) {
            XCTAssertEqual(
                $0 as? PersistenceContainerRetirementError,
                .previousContainerStillActive
            )
        }
        var budget = PersistenceContainerRetirementPollBudget(maximumPolls: 1)
        XCTAssertEqual(budget.observe(
            isReleased: !lifetimes.hasLiveContainers,
            generationMatches: true
        ), .continueWaiting)
        XCTAssertEqual(budget.observe(
            isReleased: !lifetimes.hasLiveContainers,
            generationMatches: true
        ), .timedOut)

        candidate = nil
        XCTAssertFalse(lifetimes.hasLiveContainers)
        try lifetimes.requireAllReleased()
        XCTAssertEqual(budget.observe(
            isReleased: !lifetimes.hasLiveContainers,
            generationMatches: true
        ), .retired)
    }

    @MainActor
    func testCancelledPostMountVerificationRetainsCandidateUntilItReturns() async {
        final class Container {}
        let lifetimes = PersistenceContainerLifetimeTracker<Container>()
        var finishVerification: CheckedContinuation<Void, Never>?
        var verificationTask: Task<Void, Never>?

        // A callback-backed account operation need not complete as soon as its
        // caller is cancelled. Reproduce that interval without network timing.
        await withCheckedContinuation { started in
            verificationTask = Task { @MainActor in
                let candidate = Container()
                lifetimes.track(candidate)
                await withCheckedContinuation { continuation in
                    finishVerification = continuation
                    started.resume()
                }
                withExtendedLifetime(candidate) {}
            }
        }

        verificationTask?.cancel()
        XCTAssertTrue(lifetimes.hasLiveContainers)
        XCTAssertThrowsError(try lifetimes.requireAllReleased())
        var budget = PersistenceContainerRetirementPollBudget(maximumPolls: 1)
        XCTAssertEqual(budget.observe(
            isReleased: !lifetimes.hasLiveContainers,
            generationMatches: true
        ), .continueWaiting)

        finishVerification?.resume()
        await verificationTask?.value
        XCTAssertFalse(lifetimes.hasLiveContainers)
        XCTAssertEqual(budget.observe(
            isReleased: !lifetimes.hasLiveContainers,
            generationMatches: true
        ), .retired)
    }

    func testAX5OverrideRequiresDebugUITestModeAndExplicitFlag() {
        let enabledEnvironment = [
            LocalPreviewLaunchPolicy.environmentKey: "1",
            LocalPreviewLaunchPolicy.uiTestEnvironmentKey: "1",
            LocalPreviewLaunchPolicy.accessibility5EnvironmentKey: "1"
        ]

        XCTAssertTrue(
            LocalPreviewLaunchPolicy.forcesAccessibility5(
                environment: enabledEnvironment,
                isDebugBuild: true
            )
        )
        XCTAssertFalse(
            LocalPreviewLaunchPolicy.forcesAccessibility5(
                environment: enabledEnvironment,
                isDebugBuild: false
            )
        )
        XCTAssertFalse(
            LocalPreviewLaunchPolicy.forcesAccessibility5(
                environment: [
                    LocalPreviewLaunchPolicy.environmentKey: "1",
                    LocalPreviewLaunchPolicy.accessibility5EnvironmentKey: "1"
                ],
                isDebugBuild: true
            )
        )
    }

    func testReduceMotionOverrideUsesTheRealEnvironmentOnlyInDebugUITestMode() {
        let baseEnvironment = [
            LocalPreviewLaunchPolicy.environmentKey: "1",
            LocalPreviewLaunchPolicy.uiTestEnvironmentKey: "1"
        ]
        var enabledEnvironment = baseEnvironment
        enabledEnvironment[LocalPreviewLaunchPolicy.reduceMotionEnvironmentKey] = "1"
        var disabledEnvironment = baseEnvironment
        disabledEnvironment[LocalPreviewLaunchPolicy.reduceMotionEnvironmentKey] = "0"

        XCTAssertEqual(
            LocalPreviewLaunchPolicy.forcedReduceMotion(
                environment: enabledEnvironment,
                isDebugBuild: true
            ),
            true
        )
        XCTAssertEqual(
            LocalPreviewLaunchPolicy.forcedReduceMotion(
                environment: disabledEnvironment,
                isDebugBuild: true
            ),
            false
        )
        XCTAssertNil(LocalPreviewLaunchPolicy.forcedReduceMotion(
            environment: baseEnvironment,
            isDebugBuild: true
        ))
        XCTAssertNil(LocalPreviewLaunchPolicy.forcedReduceMotion(
            environment: enabledEnvironment,
            isDebugBuild: false
        ))
        XCTAssertNil(LocalPreviewLaunchPolicy.forcedReduceMotion(
            environment: [LocalPreviewLaunchPolicy.reduceMotionEnvironmentKey: "1"],
            isDebugBuild: true
        ))
    }

    func testRequiresExplicitOneValueAndDebugBuild() {
        XCTAssertTrue(
            LocalPreviewLaunchPolicy.isEnabled(
                environment: [LocalPreviewLaunchPolicy.environmentKey: "1"],
                isDebugBuild: true
            )
        )
        XCTAssertFalse(
            LocalPreviewLaunchPolicy.isEnabled(
                environment: [LocalPreviewLaunchPolicy.environmentKey: "true"],
                isDebugBuild: true
            )
        )
        XCTAssertFalse(
            LocalPreviewLaunchPolicy.isEnabled(
                environment: [:],
                isDebugBuild: true
            )
        )
    }

    func testReleaseBuildCanNeverEnableLocalPreview() {
        XCTAssertFalse(
            LocalPreviewLaunchPolicy.isEnabled(
                environment: [LocalPreviewLaunchPolicy.environmentKey: "1"],
                isDebugBuild: false
            )
        )
    }

    func testUITestModeRequiresBothExplicitDebugFlags() {
        let enabledEnvironment = [
            LocalPreviewLaunchPolicy.environmentKey: "1",
            LocalPreviewLaunchPolicy.uiTestEnvironmentKey: "1"
        ]
        XCTAssertTrue(
            LocalPreviewLaunchPolicy.isUITestMode(
                environment: enabledEnvironment,
                isDebugBuild: true
            )
        )
        XCTAssertFalse(
            LocalPreviewLaunchPolicy.isUITestMode(
                environment: [LocalPreviewLaunchPolicy.uiTestEnvironmentKey: "1"],
                isDebugBuild: true
            )
        )
        XCTAssertFalse(
            LocalPreviewLaunchPolicy.isUITestMode(
                environment: enabledEnvironment,
                isDebugBuild: false
            )
        )
    }

    func testOrdinaryDebugSimulatorUsesPersistentLocalStore() {
        XCTAssertEqual(
            LocalPreviewLaunchPolicy.persistenceMode(
                environment: [:],
                isDebugBuild: true,
                isSimulator: true
            ),
            .persistentSimulator
        )
    }

    func testExplicitDebugPreviewRemainsInMemory() {
        XCTAssertEqual(
            LocalPreviewLaunchPolicy.persistenceMode(
                environment: [LocalPreviewLaunchPolicy.environmentKey: "1"],
                isDebugBuild: true,
                isSimulator: true
            ),
            .inMemoryPreview
        )
    }

    func testDeviceAndReleaseBuildsKeepCloudKit() {
        XCTAssertEqual(
            LocalPreviewLaunchPolicy.persistenceMode(
                environment: [:],
                isDebugBuild: true,
                isSimulator: false
            ),
            .cloudKit
        )
        XCTAssertEqual(
            LocalPreviewLaunchPolicy.persistenceMode(
                environment: [LocalPreviewLaunchPolicy.environmentKey: "1"],
                isDebugBuild: false,
                isSimulator: true
            ),
            .cloudKit
        )
    }

    func testOnlyNonCloudModesCanHostDebugFixtures() {
        XCTAssertNotEqual(
            LocalPreviewLaunchPolicy.persistenceMode(
                environment: [:],
                isDebugBuild: true,
                isSimulator: true
            ),
            .cloudKit
        )
        XCTAssertEqual(
            LocalPreviewLaunchPolicy.persistenceMode(
                environment: [:],
                isDebugBuild: true,
                isSimulator: false
            ),
            .cloudKit
        )
    }
}

private struct OfflineResumeFixture {
    let binding = ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
        accountFingerprint: String(repeating: "a", count: 64))!

    func conditions(selection: PersistenceDeploymentSelectionState? = nil,
                    mount: PersistenceDeploymentMountState? = nil,
                    complete: Bool = true, pendingTransfer: Bool = false,
                    pendingIntent: Bool = false, validSchema: Bool = true) -> CloudOfflineAccessConditions {
        CloudOfflineAccessConditions(selection: selection ?? .selected(.cloud(binding: binding)),
            mountState: mount ?? .mounted(.cloud(binding: binding)), hasExactCompleteStorePair: complete,
            hasPendingTransfer: pendingTransfer, hasPendingRemoteIntent: pendingIntent, isSchemaValid: validSchema)
    }

    func receipt(revocation: CloudOfflineRevocationReason? = nil) -> CloudOfflineAccessReceipt {
        CloudOfflineAccessReceipt(revisionID: UUID(), binding: binding, origin: .verifiedOnline,
            isDatasetGenerationKnown: true, datasetGenerationID: nil, resetBaseline: nil,
            wasUsedOffline: true, revocation: revocation)
    }

    func action(network: Bool? = true, receipt suppliedReceipt: CloudOfflineAccessReceipt? = nil,
                revocationWriteFailed: Bool = false) -> PersistenceOfflineResumeAction {
        PersistenceLaunchScenePolicy.offlineResumeAction(sessionNamespace: binding.namespace,
            activeBinding: binding, conditions: conditions(), receipt: suppliedReceipt ?? receipt(),
            revocationWriteFailed: revocationWriteFailed, networkIsOffline: network)
    }

    func action(conditions: CloudOfflineAccessConditions?) -> PersistenceOfflineResumeAction {
        PersistenceLaunchScenePolicy.offlineResumeAction(sessionNamespace: binding.namespace,
            activeBinding: binding, conditions: conditions, receipt: receipt(),
            revocationWriteFailed: false, networkIsOffline: true)
    }
}

final class PaywallContinuationTests: XCTestCase {
    @MainActor
    func testLocalSessionMaintenanceRequestLatchesExactlyOncePerProcess() {
        let router = AppRouter()

        XCTAssertFalse(router.localSessionMaintenanceRequestedThisProcess)
        XCTAssertTrue(router.requestLocalSessionMaintenanceOnce())
        XCTAssertTrue(router.localSessionMaintenanceRequestedThisProcess)
        XCTAssertFalse(router.requestLocalSessionMaintenanceOnce())
        XCTAssertTrue(router.localSessionMaintenanceRequestedThisProcess)
    }

    @MainActor
    func testHomeCustomDurationResumesExactlyOnceAfterProPurchase() {
        let router = AppRouter()

        router.presentPaywall(
            from: .customTimer,
            pendingIntent: .homeCustomDuration
        )
        router.resolvePaywallDismissal(isPro: true)

        XCTAssertNil(router.pendingPaywallIntent)
        XCTAssertTrue(router.consumeHomeCustomDurationResumeRequest())
        XCTAssertFalse(router.consumeHomeCustomDurationResumeRequest())
    }

    @MainActor
    func testHomeCustomDurationCancellationDiscardsPendingIntent() {
        let router = AppRouter()

        router.presentPaywall(
            from: .customTimer,
            pendingIntent: .homeCustomDuration
        )
        router.resolvePaywallDismissal(isPro: false)

        XCTAssertNil(router.pendingPaywallIntent)
        XCTAssertFalse(router.consumeHomeCustomDurationResumeRequest())
    }

    @MainActor
    func testSettingsCustomTimerDoesNotResumeHomeEvenWhenPro() {
        let router = AppRouter()

        router.presentPaywall(from: .customTimer, pendingIntent: .settingsCustomDuration)
        router.resolvePaywallDismissal(isPro: true)

        XCTAssertNil(router.pendingPaywallIntent)
        XCTAssertFalse(router.consumeHomeCustomDurationResumeRequest())
    }

    /// settings-08. Buying from Settings' 「カスタム」 tile reopens Settings'
    /// own editor, exactly once, the way Home's purchase path does.
    @MainActor
    func testSettingsCustomDurationResumesExactlyOnceAfterProPurchase() {
        let router = AppRouter()

        router.presentPaywall(from: .customTimer, pendingIntent: .settingsCustomDuration)
        XCTAssertEqual(router.pendingPaywallIntent, .settingsCustomDuration)
        router.resolvePaywallDismissal(isPro: true)

        XCTAssertNil(router.pendingPaywallIntent)
        XCTAssertTrue(router.consumeSettingsCustomDurationResumeRequest())
        XCTAssertFalse(router.consumeSettingsCustomDurationResumeRequest())
    }

    @MainActor
    func testSettingsCustomDurationCancellationDiscardsPendingIntent() {
        let router = AppRouter()

        router.presentPaywall(from: .customTimer, pendingIntent: .settingsCustomDuration)
        router.resolvePaywallDismissal(isPro: false)

        XCTAssertNil(router.pendingPaywallIntent)
        XCTAssertFalse(router.consumeSettingsCustomDurationResumeRequest())
    }

    @MainActor
    func testHomeCustomDurationNeverReopensSettingsEditor() {
        let router = AppRouter()

        router.presentPaywall(from: .customTimer, pendingIntent: .homeCustomDuration)
        router.resolvePaywallDismissal(isPro: true)

        XCTAssertFalse(router.consumeSettingsCustomDurationResumeRequest())
        XCTAssertTrue(router.consumeHomeCustomDurationResumeRequest())
    }

    /// An upsell with nothing to resume (Settings' Pro row, Screen Time's
    /// 「Proで勉強アプリを無制限に」) leaves both editors alone.
    @MainActor
    func testPaywallWithoutIntentResumesNothing() {
        let router = AppRouter()

        router.presentPaywall(from: .screenTimeApps)
        router.resolvePaywallDismissal(isPro: true)

        XCTAssertFalse(router.consumeHomeCustomDurationResumeRequest())
        XCTAssertFalse(router.consumeSettingsCustomDurationResumeRequest())
    }
}

final class CloudAccountAvailabilityTests: XCTestCase {
    func testPrivateDatabaseProbeHasLaunchDeadlines() {
        let operation = CloudKitOnlineAccountVerifier
            .makePrivateDatabaseProbe()

        XCTAssertEqual(
            operation.configuration.timeoutIntervalForRequest,
            CloudKitOnlineAccountVerifier.requestTimeout
        )
        XCTAssertEqual(
            operation.configuration.timeoutIntervalForResource,
            CloudKitOnlineAccountVerifier.resourceTimeout
        )
        XCTAssertLessThanOrEqual(
            CloudKitOnlineAccountVerifier.resourceTimeout,
            30
        )
    }

    func testSimulatorDoesNotOfferIneffectiveRecoveryActions() {
        XCTAssertFalse(CloudAccountAvailability.simulator.showsRefreshAction)
        XCTAssertFalse(CloudAccountAvailability.simulator.showsSettingsShortcut)
        XCTAssertTrue(CloudAccountAvailability.simulator.detail.contains("Simulator専用"))
        XCTAssertTrue(CloudAccountAvailability.simulator.detail.contains("同期しません"))
    }

    func testDeviceFailuresKeepRelevantRecoveryActions() {
        for availability in [
            CloudAccountAvailability.noAccount,
            .restricted,
            .temporarilyUnavailable,
            .unavailable
        ] {
            XCTAssertTrue(availability.showsRefreshAction)
            XCTAssertTrue(availability.showsSettingsShortcut)
        }
        XCTAssertTrue(CloudAccountAvailability.available.showsRefreshAction)
        XCTAssertFalse(CloudAccountAvailability.available.showsSettingsShortcut)
        XCTAssertFalse(CloudAccountAvailability.checking.showsRefreshAction)
        XCTAssertFalse(CloudAccountAvailability.checking.showsSettingsShortcut)
    }

#if targetEnvironment(simulator)
    @MainActor
    func testSimulatorRefreshReturnsLocalAvailabilityWithoutCloudKitLookup() async {
        let monitor = CloudSyncMonitor()

        await monitor.refresh()

        XCTAssertEqual(monitor.availability, .simulator)
    }
#endif
}

final class PurchaseConfigurationTests: XCTestCase {
    func testAppOffersOnlyTheStableLifetimeProductIdentifier() {
        XCTAssertEqual(
            IntegrationConstants.proProductID,
            "com.hinoshiba.pomogem.pro.lifetime"
        )
        XCTAssertEqual(
            IntegrationConstants.proProductIDs,
            Set([IntegrationConstants.proProductID])
        )
    }

    func testLifetimeEntitlementKeepsItsConfiguredProductIdentifier() {
        let entitlement = ProEntitlement.lifetime(
            productID: IntegrationConstants.proProductID
        )

        XCTAssertEqual(entitlement.productID, IntegrationConstants.proProductID)
    }

    func testLocalStoreKitCatalogIsOneHundredYenNonConsumableOnly() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configurationURL = projectRoot
            .appendingPathComponent("PomoGem/Resources/Products.storekit")
        let data = try Data(contentsOf: configurationURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let products = try XCTUnwrap(root["products"] as? [[String: Any]])
        let product = try XCTUnwrap(products.first)

        XCTAssertEqual(products.count, 1)
        XCTAssertEqual(
            product["productID"] as? String,
            IntegrationConstants.proProductID
        )
        XCTAssertEqual(product["type"] as? String, "NonConsumable")
        XCTAssertEqual(
            product["displayPrice"] as? String,
            String(Constants.Store.proLifetimeYen)
        )
        XCTAssertEqual(
            (root["subscriptionGroups"] as? [[String: Any]])?.count,
            0
        )
        XCTAssertEqual(
            (root["nonRenewingSubscriptions"] as? [[String: Any]])?.count,
            0
        )
    }
}


/// A stand-in for `PomoGemPersistenceLaunchHost`'s launch wiring: it owns the
/// same flags (`isPreparing`, `isWaitingForActivation`, the published session)
/// and reproduces the four parts that decide whether a deferred launch can
/// ever resume — the view task, the `catch is CancellationError` arm, the
/// UIKit `didBecomeActiveNotification` receiver and the scene-phase handler.
/// Every decision goes through the same `PersistenceLaunchScenePolicy` entry
/// points the host calls, so a change to the host's policy usage shows up
/// here; the wiring itself is still a model, and the device phases remain the
/// only end-to-end evidence.
final class DeferredLaunchCancellationRaceHostModel {
    enum Screen: Equatable { case preparing, home }

    var phase: ScenePhase = .active
    var applicationState: UIApplication.State = .active
    /// The lifecycle values the throwing checkpoint observed, which can differ
    /// from the values the catch sees after the error crosses an await.
    /// Consumed by the attempt that reads them, like the frame itself.
    var checkpointPhase: ScenePhase?
    var checkpointApplicationState: UIApplication.State?
    /// Runs inside the catch, before it decides: models an activation
    /// delivered while the CancellationError is still propagating.
    var activationDuringCancellation: (() -> Void)?

    private(set) var screen: Screen = .preparing
    private(set) var isPreparing = false
    private(set) var isWaitingForActivation = false
    private(set) var mountedSessions = 0
    private(set) var attempt = 0

    /// `.task(id: launchAttempt)` → `preparePersistenceIfNeeded()`.
    func startLaunchAttempt() {
        let attempt = self.attempt
        guard mountedSessions == 0 else { return }
        isWaitingForActivation = false
        isPreparing = true
        defer { if self.attempt == attempt { isPreparing = false } }
        let frame = consumeCheckpointFrame()
        do {
            try PersistenceLaunchScenePolicy.requireActiveAttempt(
                generationMatches: self.attempt == attempt,
                phase: frame.0,
                applicationState: frame.1
            )
            mountedSessions += 1
            screen = .home
        } catch {
            let activation = activationDuringCancellation
            activationDuringCancellation = nil
            activation?()
            var resolution = PersistenceLaunchScenePolicy.DeferredLaunchResolution.waitForActivation
            if self.attempt == attempt {
                resolution = PersistenceLaunchScenePolicy.deferredLaunchResolution(
                    phase: phase, applicationState: applicationState)
                isWaitingForActivation = resolution == .waitForActivation
            }
            if resolution == .restartImmediately { handleScenePhaseChange(.active) }
        }
    }

    /// `.onReceive(UIApplication.didBecomeActiveNotification)`.
    func deliverActivationNotification() {
        applicationState = .active
        guard PersistenceLaunchScenePolicy.shouldResumeDeferredPreparation(
            phase: phase,
            isWaitingForActivation: isWaitingForActivation,
            hasSession: mountedSessions > 0,
            isPreparing: isPreparing
        ) else { return }
        isWaitingForActivation = false
        handleScenePhaseChange(.active)
    }

    /// `.onChange(of: scenePhase)` → `handleScenePhaseChange`.
    func handleScenePhaseChange(_ next: ScenePhase) {
        phase = next
        guard PersistenceLaunchScenePolicy.action(
            phase: next,
            hasSession: mountedSessions > 0,
            isPreparing: isPreparing,
            isQuiescingAccountChange: false,
            usesCloudAccountBoundary: true
        ) == .preparePersistence else { return }
        screen = .preparing
        attempt += 1
        startLaunchAttempt()
    }

    private func consumeCheckpointFrame() -> (ScenePhase, UIApplication.State) {
        defer {
            checkpointPhase = nil
            checkpointApplicationState = nil
        }
        return (checkpointPhase ?? phase, checkpointApplicationState ?? applicationState)
    }
}

/// The real-device frame of 2026-09-20: iOS holds its own 「iCloudにサインイン」
/// alert over PomoGem, so the app stays foreground-inactive. The launch defers
/// at its first checkpoint, the account deadline is never reached, and before
/// this watchdog the preparation spinner had no timeout, no error and no button.
@MainActor
final class LaunchActivationWatchdogTests: XCTestCase {
    func testSystemAlertFrameIsBoundedByTheDocumentedLaunchBudget() {
        // Both lifecycle orders of a launch behind a system modal.
        let onScreenWithoutActivation: [(ScenePhase, UIApplication.State)] = [
            (.active, .inactive), (.inactive, .inactive), (.inactive, .active)
        ]
        for (phase, applicationState) in onScreenWithoutActivation {
            XCTAssertThrowsError(try PersistenceLaunchScenePolicy.requireActiveAttempt(
                generationMatches: true, phase: phase, applicationState: applicationState))
            XCTAssertEqual(
                LaunchActivationWatchdogPolicy.waitOutcome(phase: phase,
                    applicationState: applicationState,
                    timeout: CloudLaunchDeadline.existingStoreTimeout),
                .bounded(timeout: CloudLaunchDeadline.existingStoreTimeout))
            XCTAssertEqual(
                LaunchActivationWatchdogPolicy.waitOutcome(phase: phase,
                    applicationState: applicationState,
                    timeout: CloudLaunchDeadline.initialStoreTimeout),
                .bounded(timeout: CloudLaunchDeadline.initialStoreTimeout))
        }
        // The budget comes from the documented contract, not from a new number.
        let cloud = ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
            accountFingerprint: String(repeating: "a", count: 64))!
        XCTAssertEqual(CloudOfflineHostPolicy.launchTimeout(selection: .selected(.cloud(binding: cloud)),
            mountState: .mounted(.cloud(binding: cloud)), hasExactCompleteStorePair: true),
            CloudLaunchDeadline.existingStoreTimeout)
        XCTAssertEqual(CloudOfflineHostPolicy.launchTimeout(selection: .unselected,
            mountState: .unrecorded, hasExactCompleteStorePair: false),
            CloudLaunchDeadline.initialStoreTimeout)
    }

    func testSuspendedOrActivatedLaunchIsNeverBlamedForWaiting() {
        for applicationState in [UIApplication.State.inactive, .background, .active] {
            XCTAssertEqual(LaunchActivationWatchdogPolicy.waitOutcome(phase: .background,
                applicationState: applicationState, timeout: 12), .unbounded,
                "A suspended process must not present a failure nobody saw")
        }
        for phase in [ScenePhase.active, .inactive, .background] {
            XCTAssertEqual(LaunchActivationWatchdogPolicy.waitOutcome(phase: phase,
                applicationState: .background, timeout: 12), .unbounded)
        }
        XCTAssertEqual(LaunchActivationWatchdogPolicy.waitOutcome(phase: .active,
            applicationState: .active, timeout: 12), .unbounded,
            "An activated launch owns itself")
        for timeout in [0, -1, TimeInterval.infinity, TimeInterval.nan] {
            XCTAssertEqual(LaunchActivationWatchdogPolicy.waitOutcome(phase: .active,
                applicationState: .inactive, timeout: timeout), .unbounded)
        }
    }

    func testDeferredLaunchReachesTheRetryScreenWithinTheBudgetAndIgnoresALateActivation() async {
        let host = DeferredLaunchHostModel(phase: .active, applicationState: .inactive)
        host.offlineCopyIsEligible = true
        host.startLaunchAttempt(timeout: 0.05)
        XCTAssertTrue(host.isWaitingForActivation)
        XCTAssertEqual(host.screen, .preparing("保存方式を確認しています"),
            "The deferred launch keeps the spinner until the budget ends")
        XCTAssertFalse(host.offersRetry)

        await host.awaitRetryScreen()

        XCTAssertEqual(host.screen, .blocked(host.expectedBlockedMessage))
        XCTAssertTrue(host.offersRetry, "The protected screen must offer もう一度試す")
        XCTAssertTrue(host.offersOfflineContinuation,
            "An eligible device keeps its オフライン利用 affordance")
        XCTAssertEqual(host.retryScreenPresentations, 1)
        XCTAssertFalse(host.isWaitingForActivation)

        // The system alert is finally answered. The settled screen is no
        // longer waiting for activation, so the UIKit activation notification
        // is inert. (A scene activation is a different signal and does restart
        // the launch; see testDismissingTheSystemAlertRestartsTheLaunchItself.)
        host.applicationState = .active
        host.deliverActivationNotification()
        XCTAssertEqual(host.screen, .blocked(host.expectedBlockedMessage))
        XCTAssertEqual(host.launchAttempts, 1)
        host.tapRetry()
        XCTAssertEqual(host.launchAttempts, 2)
        XCTAssertEqual(host.screen, .home)
        XCTAssertEqual(host.retryScreenPresentations, 1)
    }

    func testActivationBeforeTheBudgetEndsCancelsItWithoutAnyRetryScreen() async {
        let host = DeferredLaunchHostModel(phase: .active, applicationState: .inactive)
        host.startLaunchAttempt(timeout: 0.05)
        XCTAssertTrue(host.watchdog.isArmed)
        host.applicationState = .active
        host.deliverActivationNotification()
        XCTAssertFalse(host.watchdog.isArmed, "Activation disarms the wait budget")
        XCTAssertEqual(host.screen, .home)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(host.retryScreenPresentations, 0)
        XCTAssertEqual(host.launchAttempts, 2)
    }

    func testBackgroundedWaitIsDisarmedAndRepeatedInactivityNeverResetsTheBudget() {
        let host = DeferredLaunchHostModel(phase: .active, applicationState: .inactive)
        host.startLaunchAttempt(timeout: 30)
        let armed = host.watchdog.armedDeadline
        XCTAssertNotNil(armed)
        XCTAssertEqual(host.watchdog.armedTimeout, 30)
        for _ in 0..<3 {
            host.handleScenePhaseChange(.inactive)
            XCTAssertTrue(host.watchdog.armedDeadline === armed,
                "One absolute budget per wait; an inactive transition must not restart it")
        }
        host.handleScenePhaseChange(.background)
        XCTAssertFalse(host.watchdog.isArmed, "The OS owns a suspended process")
        XCTAssertEqual(host.retryScreenPresentations, 0)
        // Returning to the foreground behind the same alert re-arms the wait.
        host.phase = .inactive
        host.handleScenePhaseChange(.inactive)
        XCTAssertTrue(host.watchdog.isArmed)
        XCTAssertFalse(host.watchdog.armedDeadline === armed)
        host.watchdog.cancel()
    }

    /// The arming, disarming and expiry order is product code, not test
    /// scaffolding: drive `LaunchActivationWatchdog` itself.
    /// The watchdog is armed from the generic cancellation catch, which is
    /// also where a launch lands after it has recorded a storage mode or
    /// opened a CloudKit mirror. The screen must not promise those away.
    func testTheRetryScreenOnlyPromisesWhatTheInterruptedLaunchCanProve() {
        let unchanged = LaunchActivationWatchdogPolicy.blockedMessage(progress: .nothingCommitted)
        XCTAssertTrue(unchanged.contains("記録や保存先の設定は変更していません"),
            "A wait that ran before any storage work may still reassure the user")

        for (didCommitStorageSelection, cloudMirrorWasOpened) in
            [(true, false), (false, true), (true, true)] {
            XCTAssertEqual(LaunchActivationWatchdogPolicy.launchProgress(
                didCommitStorageSelection: didCommitStorageSelection,
                cloudMirrorWasOpened: cloudMirrorWasOpened), .storageWorkCommitted)
        }
        XCTAssertEqual(LaunchActivationWatchdogPolicy.launchProgress(
            didCommitStorageSelection: false, cloudMirrorWasOpened: false), .nothingCommitted)

        let committed = LaunchActivationWatchdogPolicy.blockedMessage(progress: .storageWorkCommitted)
        XCTAssertFalse(committed.contains("変更していません"),
            "A launch that already recorded a storage mode or opened a mirror changed something")
        XCTAssertTrue(committed.contains("記録は削除していません"))
        XCTAssertTrue(committed.contains("開き直す"),
            "An opened mirror already forces a relaunch before offline use")
        // Both messages still name the cause and the remedy.
        for message in [unchanged, committed] {
            XCTAssertTrue(message.contains("起動を続けられませんでした"))
            XCTAssertTrue(message.contains("Apple Accountのサインイン"))
            XCTAssertTrue(message.contains("もう一度試す"))
        }
    }

    /// Both messages reach the screen through the same expiry path.
    func testCommittedStorageWorkChangesTheRetryScreenText() async {
        let host = DeferredLaunchHostModel(phase: .active, applicationState: .inactive)
        host.launchProgress = .storageWorkCommitted
        host.startLaunchAttempt(timeout: 0.05)
        await host.awaitRetryScreen()
        XCTAssertEqual(host.screen, .blocked(
            LaunchActivationWatchdogPolicy.blockedMessage(progress: .storageWorkCommitted)))
        XCTAssertNotEqual(host.screen, .blocked(
            LaunchActivationWatchdogPolicy.blockedMessage(progress: .nothingCommitted)))
    }

    /// The real device frame is `(scenePhase .inactive, applicationState
    /// .inactive)`: iOS owns the foreground with its Apple Account alert.
    /// Closing that alert activates the scene, and a sessionless launch screen
    /// always restarts on activation — the user does not have to press
    /// 「もう一度試す」, and the retry screen is not preserved for them.
    func testDismissingTheSystemAlertRestartsTheLaunchItself() async {
        let host = DeferredLaunchHostModel(phase: .inactive, applicationState: .inactive)
        host.startLaunchAttempt(timeout: 0.05)
        XCTAssertTrue(host.watchdog.isArmed)
        await host.awaitRetryScreen()
        XCTAssertEqual(host.screen, .blocked(host.expectedBlockedMessage))
        XCTAssertEqual(host.launchAttempts, 1)

        // The alert is dismissed: .inactive -> .active, with no tap at all.
        host.applicationState = .active
        host.handleScenePhaseChange(.active)
        XCTAssertEqual(host.screen, .home,
            "Activation restarts an unpublished launch; the blocked screen is replaced")
        XCTAssertEqual(host.launchAttempts, 2)
        XCTAssertEqual(host.retryScreenPresentations, 1)
        XCTAssertFalse(host.watchdog.isArmed)
    }

    /// The watchdog makes the retry screen reachable before the recorded
    /// selection is even read, so its 「もう一度試す」 must not stand in for the
    /// storage choice the user has never been shown.
    func testARetryAfterATimeoutNeverStandsInForTheStorageChoice() async {
        let host = DeferredLaunchHostModel(phase: .active, applicationState: .inactive)
        host.storageModeIsUnselected = true
        host.startLaunchAttempt(timeout: 0.05)
        await host.awaitRetryScreen()
        XCTAssertTrue(host.offersRetry)
        XCTAssertFalse(host.didConfirmCloudSelection)

        host.tapRetry()
        XCTAssertFalse(host.requestedCloudSelection,
            "A lifecycle timeout must not commit an unselected device to iCloud")

        // The same retry does resume a cloud launch the user did confirm.
        host.chooseCloudStorage()
        XCTAssertTrue(host.requestedCloudSelection)
        host.tapRetry()
        XCTAssertTrue(host.requestedCloudSelection)
    }

    func testRetryOnlyRestoresACloudSelectionTheUserMade() {
        XCTAssertFalse(LaunchRetryConsentPolicy.restoresPendingCloudSelection(
            storageModeIsUnselected: true, didConfirmCloudSelection: false),
            "No storage mode and no confirmation: the retry must ask first")
        XCTAssertTrue(LaunchRetryConsentPolicy.restoresPendingCloudSelection(
            storageModeIsUnselected: true, didConfirmCloudSelection: true),
            "A confirmed iCloud choice is resumed, not asked again")
        for didConfirm in [true, false] {
            XCTAssertFalse(LaunchRetryConsentPolicy.restoresPendingCloudSelection(
                storageModeIsUnselected: false, didConfirmCloudSelection: didConfirm),
                "A recorded storage mode needs no pending selection")
        }
    }

    func testWatchdogArmsOnlyForAWaitNobodyElseOwnsAndKeepsOneBudget() {
        var expiries: [Int] = []
        let watchdog = LaunchActivationWatchdog()
        let deferred = LaunchActivationWatchdog.Frame(generation: 7, hasSession: false,
            isWaitingForActivation: true, isPreparing: false, isQuiescingAccountChange: false,
            requiresStorageTransferRelaunch: false, phase: .inactive, applicationState: .inactive)

        XCTAssertTrue(watchdog.armForDeferredAttempt(frame: deferred, timeout: 30,
            expire: { expiries.append($0) }))
        XCTAssertEqual(watchdog.armedGeneration, 7)
        XCTAssertEqual(watchdog.armedTimeout, 30)
        let budget = watchdog.armedDeadline

        // A second inactive transition re-uses the same absolute budget.
        XCTAssertFalse(watchdog.armIfStillDeferred(frame: deferred, timeout: 30,
            expire: { expiries.append($0) }))
        XCTAssertTrue(watchdog.armedDeadline === budget)

        // Anything that already owns the screen refuses a fresh budget.
        watchdog.cancel()
        XCTAssertFalse(watchdog.isArmed)
        let owned: [(String, WritableKeyPath<LaunchActivationWatchdog.Frame, Bool>, Bool)] = [
            ("A published session", \.hasSession, true),
            ("A settled screen is no longer waiting", \.isWaitingForActivation, false),
            ("A running preparation owns the launch", \.isPreparing, true),
            ("Account quiescence owns the screen", \.isQuiescingAccountChange, true),
            ("A storage-transfer relaunch owns the screen", \.requiresStorageTransferRelaunch, true)
        ]
        for (reason, keyPath, value) in owned {
            var frame = deferred
            frame[keyPath: keyPath] = value
            XCTAssertFalse(watchdog.armIfStillDeferred(frame: frame, timeout: 30,
                expire: { expiries.append($0) }), reason)
            XCTAssertFalse(watchdog.isArmed, reason)
        }

        // A suspended process is never bounded, whichever entry point asks.
        var backgrounded = deferred
        backgrounded.phase = .background
        XCTAssertFalse(watchdog.armForDeferredAttempt(frame: backgrounded, timeout: 30,
            expire: { expiries.append($0) }))
        XCTAssertFalse(watchdog.armIfStillDeferred(frame: backgrounded, timeout: 30,
            expire: { expiries.append($0) }))
        XCTAssertTrue(expiries.isEmpty)
    }

    func testWatchdogScenePhaseWiringDisarmsOnBackgroundAndRearmsOnInactive() {
        let watchdog = LaunchActivationWatchdog()
        var frame = LaunchActivationWatchdog.Frame(generation: 3, hasSession: false,
            isWaitingForActivation: true, isPreparing: false, isQuiescingAccountChange: false,
            requiresStorageTransferRelaunch: false, phase: .inactive, applicationState: .inactive)
        watchdog.handleScenePhaseChange(.inactive, frame: frame, timeout: 30, expire: { _ in })
        let budget = watchdog.armedDeadline
        XCTAssertNotNil(budget)

        watchdog.handleScenePhaseChange(.inactive, frame: frame, timeout: 30, expire: { _ in })
        XCTAssertTrue(watchdog.armedDeadline === budget, "One absolute budget per wait")

        frame.phase = .background
        watchdog.handleScenePhaseChange(.background, frame: frame, timeout: 30, expire: { _ in })
        XCTAssertFalse(watchdog.isArmed)

        // .active is the host's own business: the watchdog never arms there.
        frame.phase = .active
        frame.applicationState = .active
        watchdog.handleScenePhaseChange(.active, frame: frame, timeout: 30, expire: { _ in })
        XCTAssertFalse(watchdog.isArmed)
    }

    func testWatchdogExpirySpendsTheBudgetAndRefusesASupersededGeneration() {
        let watchdog = LaunchActivationWatchdog()
        let frame = LaunchActivationWatchdog.Frame(generation: 4, hasSession: false,
            isWaitingForActivation: true, isPreparing: false, isQuiescingAccountChange: false,
            requiresStorageTransferRelaunch: false, phase: .active, applicationState: .inactive)
        watchdog.armForDeferredAttempt(frame: frame, timeout: 30, expire: { _ in })
        XCTAssertFalse(watchdog.settleExpiry(generation: 3, frame: frame),
            "A budget from a superseded attempt cannot take the screen")
        XCTAssertFalse(watchdog.isArmed, "The budget is spent either way")

        watchdog.armForDeferredAttempt(frame: frame, timeout: 30, expire: { _ in })
        XCTAssertTrue(watchdog.settleExpiry(generation: 4, frame: frame))
        XCTAssertFalse(watchdog.isArmed)
    }

    func testAnOwnedLaunchOrSettledScreenNeverGetsTheRetryScreen() {
        let cases: [(String, Bool, Bool, Bool, Bool, Bool, Bool)] = [
            ("A superseded generation", false, false, true, false, false, false),
            ("A published session", true, true, true, false, false, false),
            ("A settled screen is no longer waiting", true, false, false, false, false, false),
            ("A running preparation owns the launch", true, false, true, true, false, false),
            ("Account quiescence owns the screen", true, false, true, false, true, false),
            ("A storage-transfer relaunch owns the screen", true, false, true, false, false, true)
        ]
        for (reason, generation, hasSession, waiting, preparing, quiescing, relaunch) in cases {
            XCTAssertFalse(LaunchActivationWatchdogPolicy.presentsRetryScreen(
                generationMatches: generation, hasSession: hasSession,
                isWaitingForActivation: waiting, isPreparing: preparing,
                isQuiescingAccountChange: quiescing,
                requiresStorageTransferRelaunch: relaunch,
                phase: .active, applicationState: .inactive), reason)
        }
        XCTAssertTrue(LaunchActivationWatchdogPolicy.presentsRetryScreen(
            generationMatches: true, hasSession: false, isWaitingForActivation: true,
            isPreparing: false, isQuiescingAccountChange: false,
            requiresStorageTransferRelaunch: false,
            phase: .active, applicationState: .inactive))
        for (phase, applicationState) in [(ScenePhase.active, UIApplication.State.active),
                                          (.background, .inactive), (.inactive, .background)] {
            XCTAssertFalse(LaunchActivationWatchdogPolicy.presentsRetryScreen(
                generationMatches: true, hasSession: false, isWaitingForActivation: true,
                isPreparing: false, isQuiescingAccountChange: false,
                requiresStorageTransferRelaunch: false,
                phase: phase, applicationState: applicationState))
        }
    }
}

/// Mirrors the launch host's *launch-state* effects for the deferred-activation
/// window — the SwiftUI view task, the CancellationError catch, the UIKit
/// activation notification, the scene-phase transitions and the retry button.
/// The arm / disarm / expiry decisions are NOT re-implemented here: they are
/// driven through the product's own `LaunchActivationWatchdog`.
@MainActor
private final class DeferredLaunchHostModel {
    enum Screen: Equatable { case preparing(String), blocked(String), home }

    var phase: ScenePhase
    var applicationState: UIApplication.State
    var screen: Screen = .preparing("保存方式を確認しています")
    var offlineCopyIsEligible = false
    let watchdog = LaunchActivationWatchdog()
    private(set) var isWaitingForActivation = false
    private(set) var isPreparing = false
    private(set) var hasSession = false
    private(set) var canContinueOffline = false
    private(set) var attempt = 0
    private(set) var launchAttempts = 0
    private(set) var retryScreenPresentations = 0
    private var timeout: TimeInterval = 30

    var launchProgress = LaunchActivationWatchdogPolicy.LaunchProgress.nothingCommitted
    /// No storage mode recorded yet, as on a first launch.
    var storageModeIsUnselected = false
    private(set) var requestedCloudSelection = false
    private(set) var didConfirmCloudSelection = false
    var expectedBlockedMessage: String {
        LaunchActivationWatchdogPolicy.blockedMessage(progress: launchProgress)
    }
    var offersRetry: Bool { if case .blocked = screen { return true } else { return false } }
    var offersOfflineContinuation: Bool {
        offersRetry && canContinueOffline && !isPreparing && !hasSession
    }

    private var frame: LaunchActivationWatchdog.Frame {
        LaunchActivationWatchdog.Frame(generation: attempt, hasSession: hasSession,
            isWaitingForActivation: isWaitingForActivation, isPreparing: isPreparing,
            isQuiescingAccountChange: false, requiresStorageTransferRelaunch: false,
            phase: phase, applicationState: applicationState)
    }

    init(phase: ScenePhase, applicationState: UIApplication.State) {
        self.phase = phase
        self.applicationState = applicationState
    }

    func startLaunchAttempt(timeout: TimeInterval) {
        self.timeout = timeout
        launchAttempts += 1
        watchdog.cancel()
        isWaitingForActivation = false
        isPreparing = true
        defer { isPreparing = false }
        do {
            try PersistenceLaunchScenePolicy.requireActiveAttempt(
                generationMatches: true, phase: phase, applicationState: applicationState)
            hasSession = true
            screen = .home
        } catch {
            isWaitingForActivation = phase != .active || applicationState != .active
            guard isWaitingForActivation else { return }
            isPreparing = false
            watchdog.armForDeferredAttempt(frame: frame, timeout: timeout,
                expire: { [weak self] in self?.endWait(attempt: $0) })
        }
    }

    func awaitRetryScreen(timeout: TimeInterval = 5) async {
        let end = Date().addingTimeInterval(timeout)
        while retryScreenPresentations == 0, Date() < end {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func deliverActivationNotification() {
        guard PersistenceLaunchScenePolicy.shouldResumeDeferredPreparation(
            phase: phase, isWaitingForActivation: isWaitingForActivation,
            hasSession: hasSession, isPreparing: isPreparing) else { return }
        isWaitingForActivation = false
        watchdog.cancel()
        handleScenePhaseChange(.active)
    }

    func handleScenePhaseChange(_ next: ScenePhase) {
        phase = next
        watchdog.handleScenePhaseChange(next, frame: frame, timeout: timeout,
            expire: { [weak self] in self?.endWait(attempt: $0) })
        guard next == .active, !hasSession, !isPreparing else { return }
        attempt += 1
        screen = .preparing("保存方式を確認しています")
        startLaunchAttempt(timeout: timeout)
    }

    /// The storage-choice screen's iCloud button, behind its confirmation.
    func chooseCloudStorage() {
        requestedCloudSelection = true
        didConfirmCloudSelection = true
    }

    func tapRetry() {
        if LaunchRetryConsentPolicy.restoresPendingCloudSelection(
            storageModeIsUnselected: storageModeIsUnselected,
            didConfirmCloudSelection: didConfirmCloudSelection) {
            requestedCloudSelection = true
        }
        watchdog.cancel()
        attempt += 1
        screen = .preparing("保存領域を再確認しています")
        startLaunchAttempt(timeout: timeout)
    }

    private func endWait(attempt: Int) {
        guard watchdog.settleExpiry(generation: attempt, frame: frame) else { return }
        isWaitingForActivation = false
        canContinueOffline = offlineCopyIsEligible
        screen = .blocked(expectedBlockedMessage)
        retryScreenPresentations += 1
    }
}
