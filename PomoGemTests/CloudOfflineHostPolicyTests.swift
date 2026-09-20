import CloudKit
import XCTest
@testable import PomoGem

final class CloudOfflineHostPolicyTests: XCTestCase {
    @MainActor
    func testDeadlineAfterMirrorCreationOffersOnlineRetryBeforeAndAfterRetirement() throws {
        var now: TimeInterval = 0
        var mirrorOpened = false
        var attempt = 1
        var recovery: CloudLaunchTimeoutRecoveryAction = .remainBlocked
        let deadline = CloudLaunchDeadline(timeout: 12,
            invalidateAttempt: { attempt += 1 }, onExpiry: {
                XCTAssertEqual(attempt, 2, "The expired attempt must lose authorization before presenting recovery")
                recovery = CloudOfflineHostPolicy.timeoutRecoveryAction(
                    cloudMirrorWasOpened: mirrorOpened, hasExistingStore: true,
                    containersRetired: false, sceneIsActive: true)
            }, now: { now })
        defer { deadline.cancel() }
        now = 11
        try deadline.check()
        // A healthy request can consume the remaining budget after the
        // constructor; expiry does not prove the network went offline.
        mirrorOpened = true
        now = 12
        XCTAssertThrowsError(try deadline.check()) {
            XCTAssertEqual($0 as? CloudLaunchDeadlineError, .expired)
        }
        XCTAssertEqual(recovery, .retryOnline)
        for retired in [false, true] {
            XCTAssertEqual(CloudOfflineHostPolicy.timeoutRecoveryAction(
                cloudMirrorWasOpened: mirrorOpened, hasExistingStore: true,
                containersRetired: retired, sceneIsActive: true), .retryOnline)
            XCTAssertEqual(CloudOfflineHostPolicy.offlineMountDecision(
                cloudMirrorWasOpened: mirrorOpened, hasLiveContainers: !retired), .relaunchRequired)
        }
        XCTAssertFalse(CloudOfflineHostPolicy.prefersOfflineLaunch(explicitOnlineRetry: true,
            requestedOfflineFallback: false, networkIsOffline: nil))
        XCTAssertEqual(attempt, 2)
    }

    func testTimeoutBeforeMirrorKeepsAllExistingOfflineFallbackPrerequisites() {
        for hasStore in [false, true] {
            for retired in [false, true] {
                for active in [false, true] {
                    let action = CloudOfflineHostPolicy.timeoutRecoveryAction(
                        cloudMirrorWasOpened: false, hasExistingStore: hasStore,
                        containersRetired: retired, sceneIsActive: active)
                    XCTAssertEqual(action, hasStore && retired && active ? .openOfflineCopy : .remainBlocked)
                    XCTAssertEqual(CloudOfflineHostPolicy.timeoutRecoveryAction(
                        cloudMirrorWasOpened: true, hasExistingStore: hasStore,
                        containersRetired: retired, sceneIsActive: active), .retryOnline)
                }
            }
        }
    }

    func testExplicitOnlineRetryBypassesOnlyTheOfflinePreferenceAndNeverTheProcessFence() {
        let paths: [Bool?] = [true, false, nil]
        for path in paths {
            for fallback in [false, true] {
                XCTAssertFalse(CloudOfflineHostPolicy.prefersOfflineLaunch(explicitOnlineRetry: true,
                    requestedOfflineFallback: fallback, networkIsOffline: path))
                XCTAssertEqual(CloudOfflineHostPolicy.prefersOfflineLaunch(explicitOnlineRetry: false,
                    requestedOfflineFallback: fallback, networkIsOffline: path), fallback || path == true)
                XCTAssertEqual(CloudOfflineHostPolicy.offlineMountDecision(cloudMirrorWasOpened: true,
                    hasLiveContainers: false), .relaunchRequired)
            }
        }
    }

    func testOnlyTypedTransferAndHistoryConflictsOfferRecoveryInstructions() {
        XCTAssertEqual(CloudOfflineHostPolicy.recoveryKind(after: StorageTransferRuntimeError.remoteRecoveryRequired), .storageTransfer)
        XCTAssertEqual(CloudOfflineHostPolicy.recoveryKind(after: StorageTransferRuntimeError.datasetRefreshRequired), .storageTransfer)
        XCTAssertEqual(CloudOfflineHostPolicy.recoveryKind(after: CloudActivityHistoryPreflightError.offlineHistoryChanged), .resetHistory)
        let otherErrors: [Error] = [CloudLaunchDeadlineError.expired,
            CloudActivityHistoryPreflightError.timedOut, CloudActivityHistoryPreflightError.incompleteHistory,
            CloudStorageTransferCloudError.changedDuringRead, StorageTransferRuntimeError.relaunchRequired,
            StorageTransferRuntimeError.cloudCopyStillPending, CancellationError(),
            NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "datasetRefreshRequired"])]
        for error in otherErrors { XCTAssertNil(CloudOfflineHostPolicy.recoveryKind(after: error)) }
        for kind in [CloudAccountVerificationFailure.Kind.networkUnavailable, .serviceUnavailable,
                     .quota, .timedOut, .noAccount, .restricted, .accountChanged] {
            for error in wrappers(failure(kind)) { XCTAssertNil(CloudOfflineHostPolicy.recoveryKind(after: error)) }
        }
    }

    /// The launch host switches on `launchRoute(for:)` itself, so this table
    /// is the host's routing rather than a description of it. Every case of
    /// `StorageTransferRuntimeError` is listed: a new stop reason must be
    /// given a screen deliberately, not inherit the generic blocked one by
    /// falling through a `default`.
    func testLaunchRouteCoversEveryRuntimeErrorCase() {
        let expected: [(StorageTransferRuntimeError, CloudLaunchRoute)] = [
            (.relaunchRequired, .relaunch),
            (.remoteRecoveryRequired, .remoteRecovery),
            // Still thrown by the binding guard and the offline receipt path.
            (.datasetRefreshRequired, .datasetRefresh),
            // The two refusals that carry 「iCloudから再取得」: a terminal,
            // generation-carrying control exists for the host to refresh from.
            (.datasetReplacedRemotely, .datasetRefresh),
            (.localLedgerMissing, .datasetRefresh),
            // No lineage to refresh FROM. Its own screen, with the two
            // consented choices, instead of a door that cannot open.
            (.cloudLineageUnavailable, .lineageUnavailable),
            // Another CloudKit environment's receipt: explanation only.
            (.cloudEnvironmentMismatch, .environmentMismatch),
            // Not lineage decisions; the generic screen keeps its offline route.
            (.leftoverLocalStores, .blocked),
            (.cloudCopyStillPending, .blocked),
            (.recoveryNeedsReview, .blocked)
        ]
        for (error, route) in expected {
            XCTAssertEqual(CloudOfflineHostPolicy.launchRoute(for: error), route,
                           "\(error) must reach \(route)")
        }
        // A total table: every case above, and nothing missing. Adding a case
        // to the error without adding it here fails this count.
        XCTAssertEqual(Set(expected.map(\.0.self).map { "\($0)" }).count, 10)
    }

    /// Only the no-lineage state may name the action it offers, because only
    /// it has a screen carrying that action.
    func testTheLineageScreenIsTheOnlyRefusalThatNamesItsOwnAction() {
        XCTAssertTrue(StorageTransferRuntimeError.cloudLineageUnavailable.localizedDescription
            .contains("このiPhoneのデータでiCloudを使い始める"))
        XCTAssertEqual(CloudOfflineHostPolicy.launchRoute(for: .cloudLineageUnavailable), .lineageUnavailable)
        for error in [StorageTransferRuntimeError.cloudEnvironmentMismatch, .localLedgerMissing] {
            XCTAssertFalse(error.localizedDescription.contains("使い始める"),
                           "\(error) reaches a screen with no such control")
        }
    }

    func testRecoveryReviewIsSingleUseAndCannotRetireAChangedSessionOrAccount() {
        let binding = binding()
        let sessionID = UUID()
        let notice = CloudOfflineRecoveryPresentation.Notice(kind: .storageTransfer, sessionID: sessionID, binding: binding)
        var presentation = CloudOfflineRecoveryPresentation(notice: notice)
        XCTAssertFalse(presentation.takeReview(expectedNotice: notice, sessionID: UUID(), binding: binding))
        XCTAssertEqual(presentation.notice, notice)
        let otherAccount = ActiveAccountLocalBinding(namespace: binding.namespace,
            accountFingerprint: String(repeating: "b", count: 64))!
        XCTAssertFalse(presentation.takeReview(expectedNotice: notice, sessionID: sessionID, binding: otherAccount))
        XCTAssertEqual(presentation.notice, notice)
        XCTAssertTrue(presentation.takeReview(expectedNotice: notice, sessionID: sessionID, binding: binding))
        XCTAssertNil(presentation.notice)
        XCTAssertFalse(presentation.takeReview(expectedNotice: notice, sessionID: sessionID, binding: binding))
    }

    func testAnOldSheetCannotConsumeTheNewSessionNoticeEvenWithCurrentHostIdentity() {
        let binding = binding()
        let oldNotice = CloudOfflineRecoveryPresentation.Notice(kind: .storageTransfer,
            sessionID: UUID(), binding: binding)
        let currentNotice = CloudOfflineRecoveryPresentation.Notice(kind: .storageTransfer,
            sessionID: UUID(), binding: binding)
        var presentation = CloudOfflineRecoveryPresentation(notice: currentNotice)
        // The handler resolves current state at delivery time, but the action
        // must also carry the notice that was displayed when it was created.
        XCTAssertFalse(presentation.takeReview(expectedNotice: oldNotice,
            sessionID: currentNotice.sessionID, binding: binding))
        XCTAssertEqual(presentation.notice, currentNotice)
        XCTAssertTrue(presentation.takeReview(expectedNotice: currentNotice,
            sessionID: currentNotice.sessionID, binding: binding))
        XCTAssertNil(presentation.notice)
    }

    func testResetHistoryInstructionsCannotPretendToAuthorizeAStorageRefresh() {
        let binding = binding()
        let sessionID = UUID()
        let notice = CloudOfflineRecoveryPresentation.Notice(kind: .resetHistory, sessionID: sessionID, binding: binding)
        var presentation = CloudOfflineRecoveryPresentation(notice: notice)
        XCTAssertFalse(presentation.takeReview(expectedNotice: notice, sessionID: sessionID, binding: binding))
        XCTAssertEqual(presentation.notice, notice, "The user must keep access to the local copy and export/support instructions")
        var empty = CloudOfflineRecoveryPresentation()
        XCTAssertFalse(empty.takeReview(expectedNotice: notice, sessionID: sessionID, binding: binding))
    }

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
