import CloudKit
import XCTest
@testable import PomoGem

final class CloudOfflineHostPolicyTests: XCTestCase {
    func testExactSuccessfulCloudMountAndCompletePairUseExistingBudget() {
        let binding = binding()
        XCTAssertTrue(CloudOfflineHostPolicy.hasEstablishedCloudStore(
            selection: .selected(.cloud(binding: binding)), mountState: .mounted(.cloud(binding: binding)),
            hasExactCompleteStorePair: true))
        XCTAssertEqual(CloudOfflineHostPolicy.launchTimeout(
            selection: .selected(.cloud(binding: binding)), mountState: .mounted(.cloud(binding: binding)),
            hasExactCompleteStorePair: true), 12)
    }

    func testSelectedButNeverMountedRetryRetainsInitialThirtySecondBudget() {
        let binding = binding()
        for hasPair in [false, true] {
            XCTAssertFalse(CloudOfflineHostPolicy.hasEstablishedCloudStore(
                selection: .selected(.cloud(binding: binding)), mountState: .unrecorded,
                hasExactCompleteStorePair: hasPair))
            XCTAssertEqual(CloudOfflineHostPolicy.launchTimeout(
                selection: .selected(.cloud(binding: binding)), mountState: .unrecorded,
                hasExactCompleteStorePair: hasPair), 30)
        }
    }

    func testPartialMismatchedInvalidAndLocalOnlyStoresCannotBecomeEstablishedCloud() {
        let first = binding()
        let other = binding()
        let local = PersistenceDeploymentSelection.localOnly(namespace: first.namespace)
        let cases: [(PersistenceDeploymentSelectionState, PersistenceDeploymentMountState, Bool)] = [
            (.selected(.cloud(binding: first)), .mounted(.cloud(binding: first)), false),
            (.selected(.cloud(binding: first)), .mounted(.cloud(binding: other)), true),
            (.selected(.cloud(binding: first)), .mounted(local), true),
            (.selected(.cloud(binding: first)), .invalid, true),
            (.selected(local), .mounted(local), true),
            (.unselected, .mounted(.cloud(binding: first)), true),
            (.invalid, .mounted(.cloud(binding: first)), true)
        ]
        for (selection, mount, complete) in cases {
            XCTAssertFalse(CloudOfflineHostPolicy.hasEstablishedCloudStore(selection: selection,
                mountState: mount, hasExactCompleteStorePair: complete))
            XCTAssertEqual(CloudOfflineHostPolicy.launchTimeout(selection: selection,
                mountState: mount, hasExactCompleteStorePair: complete), 30)
        }
    }

    func testSameProcessMirroringAlwaysRequiresRelaunchRegardlessOfWeakReferences() {
        for hasLiveContainers in [false, true] {
            XCTAssertEqual(CloudOfflineHostPolicy.offlineMountDecision(cloudMirrorWasOpened: true,
                hasLiveContainers: hasLiveContainers), .relaunchRequired)
        }
        XCTAssertEqual(CloudOfflineHostPolicy.offlineMountDecision(cloudMirrorWasOpened: false,
            hasLiveContainers: true), .awaitContainerRetirement)
        XCTAssertEqual(CloudOfflineHostPolicy.offlineMountDecision(cloudMirrorWasOpened: false,
            hasLiveContainers: false), .allow)
    }

    func testOnlyConnectivityAndQuotaFailuresPermitFallbackThroughEveryRealWrapper() {
        let allowed: [CloudAccountVerificationFailure.Kind] = [
            .networkUnavailable, .serviceUnavailable, .timedOut, .quota
        ]
        let denied: [CloudAccountVerificationFailure.Kind] = [
            .noAccount, .restricted, .temporarilyUnavailable, .configuration,
            .permission, .accountChanged, .unknown
        ]
        for kind in allowed + denied {
            for wrapped in wrappers(failure(kind)) {
                XCTAssertEqual(CloudOfflineHostPolicy.allowsOfflineFallback(after: wrapped),
                    allowed.contains(kind), "\(kind)")
            }
        }
    }

    func testTypedDeadlinesAllowFallbackButHistoryDatasetAndControlChangesDoNot() {
        for error in [CloudLaunchDeadlineError.expired as Error,
                      CloudActivityHistoryPreflightError.timedOut,
                      CloudStorageTransferCloudError.timedOut] {
            XCTAssertTrue(CloudOfflineHostPolicy.allowsOfflineFallback(after: error))
            XCTAssertNil(CloudOfflineHostPolicy.revocationReason(for: error))
        }
        let blocked: [Error] = [
            CloudLaunchDeadlineError.finished, CloudLaunchDeadlineError.operationsInFlight,
            CloudActivityHistoryPreflightError.offlineHistoryChanged,
            CloudActivityHistoryPreflightError.incompleteHistory,
            CloudActivityHistoryPreflightError.malformedHistory,
            CloudActivityHistoryPreflightError.localHistoryUnavailable,
            CloudStorageTransferCloudError.changedDuringRead,
            CloudStorageTransferCloudError.unsupportedSchema,
            StorageTransferRuntimeError.datasetRefreshRequired,
            StorageTransferRuntimeError.remoteRecoveryRequired,
            StorageTransferRecoveryError.identityMismatch,
            StorageTransferRecoveryCloudTransportError.incompleteResponse,
            CancellationError()
        ]
        for error in blocked {
            XCTAssertFalse(CloudOfflineHostPolicy.allowsOfflineFallback(after: error))
            XCTAssertNil(CloudOfflineHostPolicy.revocationReason(for: error))
        }
    }

    func testPositiveIdentityFailuresRevokeThroughEveryRealWrapper() {
        let cases: [(CloudAccountVerificationFailure.Kind, CloudOfflineRevocationReason)] = [
            (.noAccount, .noAccount), (.restricted, .restricted), (.accountChanged, .accountChanged)
        ]
        for (kind, expected) in cases {
            for wrapped in wrappers(failure(kind)) {
                XCTAssertEqual(CloudOfflineHostPolicy.revocationReason(for: wrapped), expected)
                XCTAssertFalse(CloudOfflineHostPolicy.allowsOfflineFallback(after: wrapped))
            }
        }
        let mismatch = AppleAccountBoundaryResolutionError.blocked(.accountMismatch)
        XCTAssertEqual(CloudOfflineHostPolicy.revocationReason(for: mismatch), .accountMismatch)
        XCTAssertFalse(CloudOfflineHostPolicy.allowsOfflineFallback(after: mismatch))
    }

    func testUnavailableProofAndMalformedRegistryNeitherGrantFallbackNorAssertAccountChange() {
        for reason in [AppleAccountBoundaryBlockReason.identityUnavailable,
                       .invalidVerifiedIdentity, .invalidStoredRegistry] {
            let error = AppleAccountBoundaryResolutionError.blocked(reason)
            XCTAssertFalse(CloudOfflineHostPolicy.allowsOfflineFallback(after: error))
            XCTAssertNil(CloudOfflineHostPolicy.revocationReason(for: error))
        }
        for kind in [CloudAccountVerificationFailure.Kind.networkUnavailable, .serviceUnavailable,
                     .timedOut, .quota, .temporarilyUnavailable, .configuration, .permission, .unknown] {
            for wrapped in wrappers(failure(kind)) {
                XCTAssertNil(CloudOfflineHostPolicy.revocationReason(for: wrapped))
            }
        }
    }

    func testUnclassifiedErrorsAndErrorTextCannotBeUsedAsAuthorization() {
        let errors: [Error] = [
            NSError(domain: "fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "networkUnavailable noAccount accountChanged"]),
            CKError(.networkUnavailable), CKError(.notAuthenticated),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        ]
        for error in errors {
            XCTAssertFalse(CloudOfflineHostPolicy.allowsOfflineFallback(after: error))
            XCTAssertNil(CloudOfflineHostPolicy.revocationReason(for: error))
        }
    }

    private func binding() -> ActiveAccountLocalBinding {
        ActiveAccountLocalBinding(namespace: AccountDataNamespace(), accountFingerprint: String(repeating: "a", count: 64))!
    }

    private func failure(_ kind: CloudAccountVerificationFailure.Kind) -> CloudAccountVerificationFailure {
        CloudAccountVerificationFailure(kind: kind, stage: .privateDatabase)
    }

    private func wrappers(_ failure: CloudAccountVerificationFailure) -> [Error] {
        [failure, AppleAccountBoundaryResolutionError.verification(failure),
         CloudActivityHistoryPreflightError.cloud(failure), CloudStorageTransferCloudError.cloud(failure)]
    }
}
