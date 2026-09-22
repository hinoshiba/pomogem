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
                    containersRetired: false, sceneIsActive: true,
                    hasUnresolvedAccountStateMovement: false)
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
                containersRetired: retired, sceneIsActive: true,
                hasUnresolvedAccountStateMovement: false), .retryOnline)
            XCTAssertEqual(CloudOfflineHostPolicy.offlineMountDecision(
                cloudMirrorWasOpened: mirrorOpened, hasLiveContainers: !retired), .relaunchRequired)
        }
        XCTAssertFalse(CloudOfflineHostPolicy.prefersOfflineLaunch(explicitOnlineRetry: true,
            requestedOfflineFallback: false, networkIsOffline: nil,
            hasUnresolvedAccountStateMovement: false))
        XCTAssertEqual(attempt, 2)
    }

    func testTimeoutBeforeMirrorKeepsAllExistingOfflineFallbackPrerequisites() {
        for hasStore in [false, true] {
            for retired in [false, true] {
                for active in [false, true] {
                    let action = CloudOfflineHostPolicy.timeoutRecoveryAction(
                        cloudMirrorWasOpened: false, hasExistingStore: hasStore,
                        containersRetired: retired, sceneIsActive: active,
                        hasUnresolvedAccountStateMovement: false)
                    XCTAssertEqual(action, hasStore && retired && active ? .openOfflineCopy : .remainBlocked)
                    XCTAssertEqual(CloudOfflineHostPolicy.timeoutRecoveryAction(
                        cloudMirrorWasOpened: true, hasExistingStore: hasStore,
                        containersRetired: retired, sceneIsActive: active,
                        hasUnresolvedAccountStateMovement: false), .retryOnline)
                    // An unresolved account-state movement keeps every one of
                    // these combinations online: the expiry is not an answer
                    // about who is signed in.
                    XCTAssertEqual(CloudOfflineHostPolicy.timeoutRecoveryAction(
                        cloudMirrorWasOpened: false, hasExistingStore: hasStore,
                        containersRetired: retired, sceneIsActive: active,
                        hasUnresolvedAccountStateMovement: true), .retryOnline)
                }
            }
        }
    }

    func testExplicitOnlineRetryBypassesOnlyTheOfflinePreferenceAndNeverTheProcessFence() {
        let paths: [Bool?] = [true, false, nil]
        for path in paths {
            for fallback in [false, true] {
                XCTAssertFalse(CloudOfflineHostPolicy.prefersOfflineLaunch(explicitOnlineRetry: true,
                    requestedOfflineFallback: fallback, networkIsOffline: path,
                    hasUnresolvedAccountStateMovement: false))
                XCTAssertEqual(CloudOfflineHostPolicy.prefersOfflineLaunch(explicitOnlineRetry: false,
                    requestedOfflineFallback: fallback, networkIsOffline: path,
                    hasUnresolvedAccountStateMovement: false), fallback || path == true)
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
                     .quota, .timedOut, .noAccount, .restricted, .identityUnstable] {
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

    /// `localLedgerMissing` shares the refresh screen with a real remote
    /// replacement, but not its claim: a missing LOCAL ledger is this device's
    /// gap, and says nothing about whether the server's dataset was replaced.
    /// The two titles are therefore different strings.
    func testTheRefreshScreenOnlyClaimsAReplacementWhenOneWasObserved() {
        XCTAssertEqual(CloudOfflineHostPolicy.launchRoute(for: .datasetReplacedRemotely), .datasetRefresh)
        XCTAssertEqual(CloudOfflineHostPolicy.launchRoute(for: .localLedgerMissing), .datasetRefresh)
        XCTAssertFalse(StorageTransferRuntimeError.localLedgerMissing.localizedDescription
            .contains("置き換え"),
            "The local ledger gap must not be reported as a replacement")
        XCTAssertTrue(StorageTransferRuntimeError.datasetReplacedRemotely.localizedDescription
            .contains("置き換え"))
        XCTAssertNotEqual(StorageTransferLineageCopy.localLedgerMissingTitle,
                          "iCloudのデータが置き換わりました")
    }

    /// review-2-5. No stop reason names a control any more: the sentence that
    /// does belongs to the SCREEN, which knows whether the build publishes it.
    /// The screen the no-lineage state reaches is still its own.
    func testNoStopReasonNamesAControlAndTheScreenBuildsItFromThePolicy() {
        for error in [StorageTransferRuntimeError.cloudLineageUnavailable,
                      .cloudEnvironmentMismatch, .localLedgerMissing] {
            XCTAssertFalse(error.localizedDescription.contains("使い始める"),
                           "\(error) must not promise a control the build may ship disabled")
        }
        XCTAssertEqual(CloudOfflineHostPolicy.launchRoute(for: .cloudLineageUnavailable), .lineageUnavailable)
        XCTAssertTrue(StorageTransferLineageCopy.screenMessage(offersLineageStart: true)
            .contains("このiPhoneのデータでiCloudを使い始めるか、オフラインのまま使うかを選べます。"))
        XCTAssertFalse(StorageTransferLineageCopy.screenMessage(offersLineageStart: false)
            .contains("選べます"),
            "While the door ships disabled the screen may not state that choice")
        XCTAssertTrue(StorageTransferLineageCopy.screenMessage(offersLineageStart: false)
            .contains("もう一度試す"),
            "It must instead name a control the screen actually carries")
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
            .permission, .identityUnstable, .unknown
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
            (.noAccount, .noAccount), (.restricted, .restricted)
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
                     .timedOut, .quota, .temporarilyUnavailable, .configuration, .permission,
                     .identityUnstable, .unknown] {
            for wrapped in wrappers(failure(kind)) {
                XCTAssertNil(CloudOfflineHostPolicy.revocationReason(for: wrapped))
            }
        }
    }

    /// The device receipt recovered on 2026-09-21 carried `accountChanged`
    /// while every other artifact said the account was unchanged. That reason
    /// could be written by a proof whose two identity reads disagreed with
    /// each other — a comparison of two momentary values that never looked at
    /// the stored binding. Only the resolver's own verdict may revoke.
    func testAnIdentityThatDisagreedWithItselfIsTransientAndNeverRevokes() {
        let unstable = CloudAccountVerificationFailure(kind: .identityUnstable,
            stage: .identityAfterProbe)
        for wrapped in wrappers(unstable) {
            XCTAssertNil(CloudOfflineHostPolicy.revocationReason(for: wrapped),
                "An identity read that disagreed with itself compared nothing to the stored binding")
            XCTAssertFalse(CloudOfflineHostPolicy.allowsOfflineFallback(after: wrapped),
                "Refusing to revoke must not also relax the fail-closed launch route")
        }
        // The same proof is worth repeating once: nothing about it says which
        // account is signed in, and no server asked the app to wait.
        XCTAssertEqual(CloudAccountIdentityVerifier.nextAttemptDelay(after: unstable, defaultDelay: 0), 0)
        XCTAssertEqual(CloudAccountIdentityVerifier.nextAttemptDelay(after: unstable, defaultDelay: 0.5), 0.5)
        XCTAssertEqual(CloudAccountIdentityVerifier.nextAttemptDelay(after: unstable, defaultDelay: 90), 3)
        for invalid in [TimeInterval.nan, -1, -TimeInterval.infinity] {
            XCTAssertNil(CloudAccountIdentityVerifier.nextAttemptDelay(after: unstable, defaultDelay: invalid))
        }
        // Reasons that really are a positive account state keep revoking, and
        // keep their own retry rules.
        for kind in [CloudAccountVerificationFailure.Kind.noAccount, .restricted, .unknown, .quota] {
            XCTAssertNil(CloudAccountIdentityVerifier.nextAttemptDelay(
                after: failure(kind), defaultDelay: 0.5), "\(kind)")
        }
        XCTAssertEqual(CloudAccountIdentityVerifier.nextAttemptDelay(
            after: failure(.networkUnavailable), defaultDelay: 0.5), 0.5)
    }

    /// The reasons that survive are exactly the ones a comparison or a
    /// positive account state produced. `accountChanged` is still decodable so
    /// receipts already on a phone keep their meaning, but nothing writes it.
    func testOnlyComparedOrPositiveAccountStatesRemainWritableRevocationReasons() {
        let mismatch = AppleAccountBoundaryResolutionError.blocked(.accountMismatch)
        XCTAssertEqual(CloudOfflineHostPolicy.revocationReason(for: mismatch), .accountMismatch)
        XCTAssertEqual(CloudOfflineHostPolicy.revocationReason(
            for: failure(.noAccount)), .noAccount)
        XCTAssertEqual(CloudOfflineHostPolicy.revocationReason(
            for: failure(.restricted)), .restricted)
        var written: Set<CloudOfflineRevocationReason> = []
        for kind in allKinds {
            for wrapped in wrappers(failure(kind)) {
                if let reason = CloudOfflineHostPolicy.revocationReason(for: wrapped) {
                    written.insert(reason)
                }
            }
        }
        for blocked in [AppleAccountBoundaryBlockReason.accountMismatch, .identityUnavailable,
                        .invalidVerifiedIdentity, .invalidStoredRegistry] {
            if let reason = CloudOfflineHostPolicy.revocationReason(
                for: AppleAccountBoundaryResolutionError.blocked(blocked)) {
                written.insert(reason)
            }
        }
        XCTAssertEqual(written, [.accountMismatch, .noAccount, .restricted])
        XCTAssertFalse(written.contains(.accountChanged),
            "No classified failure may write the reason that compared nothing")
    }

    private var allKinds: [CloudAccountVerificationFailure.Kind] {
        [.noAccount, .restricted, .temporarilyUnavailable, .networkUnavailable,
         .serviceUnavailable, .configuration, .permission, .quota,
         .identityUnstable, .timedOut, .unknown]
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

    /// The notification that started the device incident. It is posted for
    /// sign-in and sign-out, for iCloud being switched on or off for this app,
    /// for token refreshes and for availability transitions, and it carries no
    /// identity — so on no selection at all may it write to the durable
    /// receipt. Before this was extracted, the decision lived inside a private
    /// View and nothing could reach it.
    func testABareAccountStateNotificationNeverAuthorizesARevocation() {
        let selections: [PersistenceDeploymentSelectionState] = [
            .selected(.cloud(binding: binding())),
            .selected(.localOnly(namespace: AccountDataNamespace())),
            .unselected, .invalid
        ]
        for selection in selections {
            XCTAssertEqual(CloudOfflineHostPolicy.reactionToAccountStateNotification(
                selection: selection), .quiesceOnly, "\(selection)")
        }
    }

    /// The offline route opens the local copy on the receipt alone. While a
    /// movement of account state is unresolved, the receipt cannot say who is
    /// signed in, so no combination of an offline network path, an offline
    /// fallback request or an expiry may take that route.
    func testAnUnresolvedAccountStateMovementWithdrawsEveryOfflineLaunchRoute() {
        let paths: [Bool?] = [true, false, nil]
        for path in paths {
            for fallback in [false, true] {
                for retry in [false, true] {
                    XCTAssertFalse(CloudOfflineHostPolicy.prefersOfflineLaunch(
                        explicitOnlineRetry: retry, requestedOfflineFallback: fallback,
                        networkIsOffline: path, hasUnresolvedAccountStateMovement: true),
                        "path=\(String(describing: path)) fallback=\(fallback) retry=\(retry)")
                }
                // Same inputs, movement resolved: the ordinary rule returns.
                XCTAssertEqual(CloudOfflineHostPolicy.prefersOfflineLaunch(
                    explicitOnlineRetry: false, requestedOfflineFallback: fallback,
                    networkIsOffline: path, hasUnresolvedAccountStateMovement: false),
                    fallback || path == true)
            }
        }
    }

    /// The blocked launch says why the local copy is not on offer, but only
    /// when that is actually the reason. A failure that would not have opened
    /// the copy anyway, and a receipt that is not eligible, keep their own
    /// message rather than blaming an account change for them.
    func testTheWithdrawnOfflineDoorIsExplainedOnlyWhenItIsWhatIsMissing() {
        let recoverable: Error = CloudLaunchDeadlineError.expired
        let message = CloudOfflineHostPolicy.unresolvedAccountMovementMessage(
            after: recoverable, hasUnresolvedAccountStateMovement: true,
            offlineCopyWouldOtherwiseBeEligible: true)
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("もう一度試す") == true)
        XCTAssertNil(CloudOfflineHostPolicy.unresolvedAccountMovementMessage(
            after: recoverable, hasUnresolvedAccountStateMovement: false,
            offlineCopyWouldOtherwiseBeEligible: true))
        XCTAssertNil(CloudOfflineHostPolicy.unresolvedAccountMovementMessage(
            after: recoverable, hasUnresolvedAccountStateMovement: true,
            offlineCopyWouldOtherwiseBeEligible: false))
        XCTAssertNil(CloudOfflineHostPolicy.unresolvedAccountMovementMessage(
            after: failure(.noAccount), hasUnresolvedAccountStateMovement: true,
            offlineCopyWouldOtherwiseBeEligible: true))
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
