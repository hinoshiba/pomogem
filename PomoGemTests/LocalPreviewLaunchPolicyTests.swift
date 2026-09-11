import Foundation
import XCTest
@testable import PomoGem

final class LocalPreviewLaunchPolicyTests: XCTestCase {
    func testFirstActiveSceneRetriesBeforeStorageSelection() {
        XCTAssertEqual(
            PersistenceLaunchScenePolicy.action(
                isActive: true,
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
                isActive: true,
                hasSession: true,
                isPreparing: false,
                isQuiescingAccountChange: false,
                usesCloudAccountBoundary: true
            ),
            .none
        )
        XCTAssertEqual(
            PersistenceLaunchScenePolicy.action(
                isActive: true,
                hasSession: false,
                isPreparing: false,
                isQuiescingAccountChange: true,
                usesCloudAccountBoundary: true
            ),
            .none
        )
    }

    func testOnlyCloudWorkRetiresWhenSceneLeavesActiveState() {
        XCTAssertEqual(
            PersistenceLaunchScenePolicy.action(
                isActive: false,
                hasSession: false,
                isPreparing: true,
                isQuiescingAccountChange: false,
                usesCloudAccountBoundary: true
            ),
            .retireCloudSession
        )
        XCTAssertEqual(
            PersistenceLaunchScenePolicy.action(
                isActive: false,
                hasSession: true,
                isPreparing: false,
                isQuiescingAccountChange: false,
                usesCloudAccountBoundary: false
            ),
            .none
        )
    }

    func testBackgroundTransitionDoesNotRestartAnInactiveRetirement() {
        for isPreparing in [false, true] {
            XCTAssertEqual(
                PersistenceLaunchScenePolicy.action(
                    isActive: false,
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
                isActive: true,
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
                isActive: true,
                hasSession: false,
                isPreparing: isPreparing,
                isQuiescingAccountChange: true,
                usesCloudAccountBoundary: true,
                didTimeOutContainerRetirement: false,
                hasRetiringContainers: false
            ), .none)
        }
        XCTAssertEqual(PersistenceLaunchScenePolicy.action(
            isActive: false,
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
