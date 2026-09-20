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
    /// Driven through `DeferredLaunchHostModel`, which owns the flags the host
    /// owns: reverting the assignment in the host's `catch is CancellationError`
    /// arm, or removing the activation receiver, now fails this test instead of
    /// leaving the suite green.
    func testHalfActivatedLaunchFrameDefersInsteadOfBlockingOnTheAccount() {
        let host = DeferredLaunchHostModel()
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
        let host = DeferredLaunchHostModel()
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
            let host = DeferredLaunchHostModel()
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

    func testInactivePublishedSessionStillRetiresWhenItEntersBackground() {
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
        // Moving from a system panel to another app must still close the
        // CloudKit store before a later foreground account verification.
        XCTAssertEqual(action(.background), .retireCloudSession)
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

        router.presentPaywall(from: .customTimer)
        router.resolvePaywallDismissal(isPro: true)

        XCTAssertNil(router.pendingPaywallIntent)
        XCTAssertFalse(router.consumeHomeCustomDurationResumeRequest())
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
final class DeferredLaunchHostModel {
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
