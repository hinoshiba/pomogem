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

        XCTAssertEqual(host.screen, .blocked(LaunchActivationWatchdogPolicy.blockedMessage))
        XCTAssertTrue(host.offersRetry, "The protected screen must offer もう一度試す")
        XCTAssertTrue(host.offersOfflineContinuation,
            "An eligible device keeps its オフライン利用 affordance")
        XCTAssertEqual(host.retryScreenPresentations, 1)
        XCTAssertFalse(host.isWaitingForActivation)

        // The system alert is finally answered. A late activation cannot
        // silently replace the settled screen; only an explicit retry may.
        host.applicationState = .active
        host.deliverActivationNotification()
        XCTAssertEqual(host.screen, .blocked(LaunchActivationWatchdogPolicy.blockedMessage))
        XCTAssertEqual(host.launchAttempts, 1)
        host.tapRetry()
        XCTAssertEqual(host.launchAttempts, 2)
        XCTAssertEqual(host.screen, .home)
        XCTAssertEqual(host.retryScreenPresentations, 1)
    }

    func testActivationBeforeTheBudgetEndsCancelsItWithoutAnyRetryScreen() async {
        let host = DeferredLaunchHostModel(phase: .active, applicationState: .inactive)
        host.startLaunchAttempt(timeout: 0.05)
        XCTAssertTrue(host.hasArmedWatchdog)
        host.applicationState = .active
        host.deliverActivationNotification()
        XCTAssertFalse(host.hasArmedWatchdog, "Activation disarms the wait budget")
        XCTAssertEqual(host.screen, .home)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(host.retryScreenPresentations, 0)
        XCTAssertEqual(host.launchAttempts, 2)
    }

    func testBackgroundedWaitIsDisarmedAndRepeatedInactivityNeverResetsTheBudget() {
        let host = DeferredLaunchHostModel(phase: .active, applicationState: .inactive)
        host.startLaunchAttempt(timeout: 30)
        let armed = host.armedWatchdog
        XCTAssertNotNil(armed)
        for _ in 0..<3 {
            host.handleScenePhaseChange(.inactive)
            XCTAssertTrue(host.armedWatchdog === armed,
                "One absolute budget per wait; an inactive transition must not restart it")
        }
        host.handleScenePhaseChange(.background)
        XCTAssertFalse(host.hasArmedWatchdog, "The OS owns a suspended process")
        XCTAssertEqual(host.retryScreenPresentations, 0)
        // Returning to the foreground behind the same alert re-arms the wait.
        host.phase = .inactive
        host.handleScenePhaseChange(.inactive)
        XCTAssertTrue(host.hasArmedWatchdog)
        XCTAssertFalse(host.armedWatchdog === armed)
        host.cancelWatchdog()
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

/// Mirrors the launch host's wiring for the deferred-activation window: the
/// SwiftUI view task, the CancellationError catch, the UIKit activation
/// notification, the scene-phase transitions and the retry button.
@MainActor
private final class DeferredLaunchHostModel {
    enum Screen: Equatable { case preparing(String), blocked(String), home }

    var phase: ScenePhase
    var applicationState: UIApplication.State
    var screen: Screen = .preparing("保存方式を確認しています")
    var offlineCopyIsEligible = false
    private(set) var isWaitingForActivation = false
    private(set) var isPreparing = false
    private(set) var hasSession = false
    private(set) var canContinueOffline = false
    private(set) var attempt = 0
    private(set) var launchAttempts = 0
    private(set) var retryScreenPresentations = 0
    private(set) var armedWatchdog: CloudLaunchDeadline?

    var hasArmedWatchdog: Bool { armedWatchdog != nil }
    var offersRetry: Bool { if case .blocked = screen { return true } else { return false } }
    var offersOfflineContinuation: Bool {
        offersRetry && canContinueOffline && !isPreparing && !hasSession
    }

    init(phase: ScenePhase, applicationState: UIApplication.State) {
        self.phase = phase
        self.applicationState = applicationState
    }

    func startLaunchAttempt(timeout: TimeInterval) {
        launchAttempts += 1
        cancelWatchdog()
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
            armWatchdog(attempt: attempt, timeout: timeout)
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
        cancelWatchdog()
        handleScenePhaseChange(.active)
    }

    func handleScenePhaseChange(_ next: ScenePhase) {
        phase = next
        if next == .background {
            cancelWatchdog()
        } else if next == .inactive {
            armWatchdogIfDeferred()
        }
        guard next == .active, !hasSession, !isPreparing else { return }
        attempt += 1
        screen = .preparing("保存方式を確認しています")
        startLaunchAttempt(timeout: 0.05)
    }

    func tapRetry() {
        cancelWatchdog()
        attempt += 1
        screen = .preparing("保存領域を再確認しています")
        startLaunchAttempt(timeout: 0.05)
    }

    private func armWatchdogIfDeferred() {
        guard isWaitingForActivation, !hasSession, !isPreparing,
              armedWatchdog == nil else { return }
        armWatchdog(attempt: attempt, timeout: 30)
    }

    private func armWatchdog(attempt: Int, timeout: TimeInterval) {
        cancelWatchdog()
        guard case let .bounded(bounded) = LaunchActivationWatchdogPolicy.waitOutcome(
            phase: phase, applicationState: applicationState, timeout: timeout) else { return }
        armedWatchdog = CloudLaunchDeadline(timeout: bounded, invalidateAttempt: {},
            onExpiry: { [weak self] in self?.endWait(attempt: attempt) })
    }

    func cancelWatchdog() {
        armedWatchdog?.cancel()
        armedWatchdog = nil
    }

    private func endWait(attempt: Int) {
        armedWatchdog = nil
        guard LaunchActivationWatchdogPolicy.presentsRetryScreen(
            generationMatches: self.attempt == attempt, hasSession: hasSession,
            isWaitingForActivation: isWaitingForActivation, isPreparing: isPreparing,
            isQuiescingAccountChange: false, requiresStorageTransferRelaunch: false,
            phase: phase, applicationState: applicationState) else { return }
        isWaitingForActivation = false
        canContinueOffline = offlineCopyIsEligible
        screen = .blocked(LaunchActivationWatchdogPolicy.blockedMessage)
        retryScreenPresentations += 1
    }
}
