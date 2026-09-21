import Foundation

enum CloudOfflineMountDecision: Equatable, Sendable {
    case allow, relaunchRequired, awaitContainerRetirement
}

enum CloudLaunchTimeoutRecoveryAction: Equatable, Sendable {
    case retryOnline, openOfflineCopy, remainBlocked
}

enum CloudOfflineRecoveryKind: Equatable, Sendable {
    case storageTransfer, resetHistory
}

/// A presentation hint bound to the currently published local copy. Consuming
/// the explicit review action is synchronous, so double taps and old sheets
/// cannot retire another session. It grants no cloud or deletion authority.
struct CloudOfflineRecoveryPresentation: Equatable, Sendable {
    struct Notice: Equatable, Sendable {
        let kind: CloudOfflineRecoveryKind
        let sessionID: UUID
        let binding: ActiveAccountLocalBinding
    }
    var notice: Notice?

    mutating func takeReview(expectedNotice: Notice, sessionID: UUID, binding: ActiveAccountLocalBinding) -> Bool {
        guard let notice, notice == expectedNotice, notice.kind == .storageTransfer,
              notice.sessionID == sessionID, notice.binding == binding else { return false }
        self.notice = nil
        return true
    }
}

/// What the launch host may do when CloudKit reports that account state moved.
///
/// Quiescing closes the boundary: scheduling is suspended, the cross-process
/// binding is cleared, the containers are retired and the launch starts over.
/// A revocation is durable and outlives every relaunch, so it is a separate,
/// louder step that only a completed comparison may reach.
enum CloudOfflineAccountStateReaction: Equatable, Sendable {
    case quiesceOnly
    case revokeThenQuiesce(binding: ActiveAccountLocalBinding, reason: CloudOfflineRevocationReason)
}

enum CloudOfflineSessionError: Error, LocalizedError {
    case relaunchRequired

    var errorDescription: String? {
        "端末の記録を保護したままオフラインで開くため、先ほどの同期処理を終了する必要があります。アプリスイッチャーでPomoGemを終了し、もう一度開いてください。アプリ自体は削除しないでください。"
    }
}

/// Pure host decisions. None of these classifications authorizes offline
/// access by itself: the durable receipt, selected account namespace, exact
/// store pair, scene lease, and transfer/intent gates still have to succeed.
enum CloudOfflineHostPolicy {
    static func recoveryKind(after error: Error) -> CloudOfflineRecoveryKind? {
        switch error {
        case StorageTransferRuntimeError.remoteRecoveryRequired,
             StorageTransferRuntimeError.datasetRefreshRequired: .storageTransfer
        case CloudActivityHistoryPreflightError.offlineHistoryChanged: .resetHistory
        default: nil
        }
    }

    /// Explicit online retry changes only the preferred launch route. It does
    /// not permit .none after a mirror or bypass the usual online preflights.
    ///
    /// `hasUnresolvedAccountStateMovement` is the one input that can withdraw
    /// the offline route entirely. The offline route opens the local copy on
    /// the durable receipt alone — `openOfflineSession` performs no identity
    /// work — so it is only ever as trustworthy as the last completed boundary
    /// resolution. Once this process has been told the account state moved and
    /// has not resolved the boundary since, the receipt no longer stands for a
    /// checked identity, and the launch has to go online to learn who is
    /// signed in. A movement it cannot resolve fails the launch closed rather
    /// than reopening the previous account's namespace.
    static func prefersOfflineLaunch(explicitOnlineRetry: Bool, requestedOfflineFallback: Bool,
                                     networkIsOffline: Bool?,
                                     hasUnresolvedAccountStateMovement: Bool) -> Bool {
        guard !hasUnresolvedAccountStateMovement else { return false }
        return !explicitOnlineRetry && (requestedOfflineFallback || networkIsOffline == true)
    }

    /// What a bare account-state notification authorizes.
    ///
    /// `.CKAccountChanged` is posted for every movement of account state —
    /// signing in or out, iCloud being switched on or off for this app, a
    /// token refresh, an availability transition. It carries no identity and
    /// compares nothing against the stored binding, so on every selection it
    /// buys exactly one thing: closing the boundary and resolving the identity
    /// again. It never writes to the durable receipt. The reason a comparison
    /// produces is written later, by `revokeOfflineForAccountError`, from the
    /// resolution this quiescence starts.
    ///
    /// The switch is exhaustive on purpose. A selection the notification may
    /// act on differently has to say so here, where it can be tested, rather
    /// than inside the launch view where nothing can reach it.
    static func reactionToAccountStateNotification(
        selection: PersistenceDeploymentSelectionState
    ) -> CloudOfflineAccountStateReaction {
        switch selection {
        case .selected, .unselected, .invalid: .quiesceOnly
        }
    }

    /// Why a launch that could otherwise have offered the local copy is
    /// blocked instead. Returns nil whenever the ordinary message applies, so
    /// this never rewrites a failure it does not explain.
    static func unresolvedAccountMovementMessage(
        after error: Error,
        hasUnresolvedAccountStateMovement: Bool,
        offlineCopyWouldOtherwiseBeEligible: Bool
    ) -> String? {
        guard hasUnresolvedAccountStateMovement, offlineCopyWouldOtherwiseBeEligible,
              allowsOfflineFallback(after: error) else { return nil }
        return "Apple Accountの状態が変わったため、どのApple Accountでサインインしているかを確認するまで、この端末に保存したデータは開きません。通信が使える場所で「もう一度試す」をタップしてください。記録は消えていません。"
    }

    static func hasEstablishedCloudStore(
        selection: PersistenceDeploymentSelectionState,
        mountState: PersistenceDeploymentMountState,
        hasExactCompleteStorePair: Bool
    ) -> Bool {
        guard case let .selected(.cloud(binding)) = selection,
              mountState == .mounted(.cloud(binding: binding)),
              hasExactCompleteStorePair else { return false }
        return true
    }

    static func launchTimeout(
        selection: PersistenceDeploymentSelectionState,
        mountState: PersistenceDeploymentMountState,
        hasExactCompleteStorePair: Bool
    ) -> TimeInterval {
        hasEstablishedCloudStore(selection: selection, mountState: mountState,
            hasExactCompleteStorePair: hasExactCompleteStorePair)
            ? CloudLaunchDeadline.existingStoreTimeout : CloudLaunchDeadline.initialStoreTimeout
    }

    /// A weak ModelContainer reference cannot prove that Core Data's earlier
    /// mirroring engine stopped. A process that opened it cannot subsequently
    /// reopen those same SQLite files as writable `.none` stores.
    static func offlineMountDecision(
        cloudMirrorWasOpened: Bool,
        hasLiveContainers: Bool
    ) -> CloudOfflineMountDecision {
        if cloudMirrorWasOpened { return .relaunchRequired }
        if hasLiveContainers { return .awaitContainerRetirement }
        return .allow
    }

    /// Expiry is not evidence that networking is unavailable. Once a mirror
    /// was opened, keep the online retry path instead of attempting a `.none`
    /// fallback that the process fence must reject. An offline candidate still
    /// has to pass all receipt, account, schema and store checks when opened.
    ///
    /// An unresolved account-state movement keeps the online path for the same
    /// reason: the expiry says nothing about who is signed in, and opening the
    /// local copy is precisely what must wait for an answer. Returning
    /// `.openOfflineCopy` there would also spin, because the offline route
    /// refuses the request and the next expiry would ask again.
    static func timeoutRecoveryAction(
        cloudMirrorWasOpened: Bool,
        hasExistingStore: Bool,
        containersRetired: Bool,
        sceneIsActive: Bool,
        hasUnresolvedAccountStateMovement: Bool
    ) -> CloudLaunchTimeoutRecoveryAction {
        if cloudMirrorWasOpened { return .retryOnline }
        if hasUnresolvedAccountStateMovement { return .retryOnline }
        if hasExistingStore && containersRetired && sceneIsActive { return .openOfflineCopy }
        return .remainBlocked
    }

    static func allowsOfflineFallback(after error: Error) -> Bool {
        switch error {
        case CloudLaunchDeadlineError.expired,
             CloudActivityHistoryPreflightError.timedOut,
             CloudStorageTransferCloudError.timedOut:
            return true
        default: break
        }
        guard let failure = accountFailure(in: error) else { return false }
        switch failure.kind {
        case .networkUnavailable, .serviceUnavailable, .timedOut, .quota:
            return true
        case .noAccount, .restricted, .temporarilyUnavailable, .configuration,
             .permission, .identityUnstable, .unknown:
            return false
        }
    }

    /// Only a positive account result revokes local access. Ambiguous transport,
    /// record/schema errors and cancellation cannot be promoted into identity
    /// evidence merely because their descriptions mention an account.
    static func revocationReason(for error: Error) -> CloudOfflineRevocationReason? {
        // The only comparison between the live verified identity and the
        // stored binding lives in the boundary resolver. Its verdict is the
        // only thing that can assert "a different Apple Account".
        if case AppleAccountBoundaryResolutionError.blocked(.accountMismatch) = error {
            return .accountMismatch
        }
        guard let failure = accountFailure(in: error) else { return nil }
        switch failure.kind {
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        // Two identity reads inside one proof that disagreed with each other
        // never touched the stored binding. Treating that as durable identity
        // evidence is exactly the promotion this function's contract forbids;
        // the retried proof, and its comparison, decide instead.
        case .identityUnstable: return nil
        default: return nil
        }
    }

    private static func accountFailure(in error: Error) -> CloudAccountVerificationFailure? {
        switch error {
        case let failure as CloudAccountVerificationFailure: return failure
        case let AppleAccountBoundaryResolutionError.verification(failure): return failure
        case let CloudActivityHistoryPreflightError.cloud(failure): return failure
        // The ordinary pre-mirror transfer-control read uses this sanitized
        // transport wrapper as well, including before the first container.
        case let CloudStorageTransferCloudError.cloud(failure): return failure
        default: return nil
        }
    }
}

/// The launch step that retracts a revocation no identity comparison ever
/// supported, and reopens the offline door in the same launch attempt.
///
/// It lives here, outside the private launch view, so that both the decision
/// and its ORDER can be tested. The order is the whole point: the retraction
/// has to happen while the only thing the launch has proved is the identity.
/// The transfer and lineage preflights that run afterwards can block a launch
/// long before any cloud mount is reached, and a mount is the only other way
/// a revocation is ever cleared — so a retraction moved after them would never
/// run at all on the phones this exists for.
///
/// Nothing here certifies lineage, remote history or a mount, and it cannot
/// widen what may be retracted: `clearRevocationAfterConfirmedIdentity` still
/// requires the receipt to name the confirmed binding and the reason to be one
/// `CloudOfflineAccessPolicy.isRetractableByConfirmedIdentity` allows.
@MainActor
struct CloudOfflineLaunchRecovery {
    struct Outcome: Equatable, Sendable {
        /// The reason that was dropped, or nil when nothing was retracted.
        var retractedReason: CloudOfflineRevocationReason?
        /// Whether the local copy may be offered after the retraction. This
        /// is re-read from the receipt, never inferred from the retraction.
        var offlineCopyIsEligible: Bool
        /// The receipt could not be read or written. The launch continues;
        /// the receipt simply stays exactly as it was.
        var failed: Bool
    }

    /// The binding the stored selection expects, or nil when nothing is
    /// selected yet. A launch that resolved a different account than the one
    /// the receipt names retracts nothing.
    let expectedBinding: ActiveAccountLocalBinding?
    /// The binding a COMPLETED online boundary resolution produced: a verified
    /// account fingerprint that the namespace registry resolved to exactly
    /// this binding.
    let resolvedBinding: ActiveAccountLocalBinding

    func run(
        state: CloudOfflineAccessState?,
        isEligible: (ActiveAccountLocalBinding) -> Bool
    ) -> Outcome {
        guard let state, expectedBinding == resolvedBinding else {
            return Outcome(retractedReason: nil,
                offlineCopyIsEligible: isEligible(resolvedBinding), failed: state == nil)
        }
        do {
            let before = try state.load()?.revocation
            let retracted = try state.clearRevocationAfterConfirmedIdentity(
                confirmedBinding: resolvedBinding)
            return Outcome(retractedReason: retracted == nil ? nil : before,
                offlineCopyIsEligible: isEligible(resolvedBinding), failed: false)
        } catch {
            return Outcome(retractedReason: nil,
                offlineCopyIsEligible: isEligible(resolvedBinding), failed: true)
        }
    }

    /// The same step, with the launch's next step passed in, so the retraction
    /// cannot be reordered behind a preflight without deleting this call.
    @discardableResult
    func run<Value>(
        state: CloudOfflineAccessState?,
        isEligible: (ActiveAccountLocalBinding) -> Bool,
        record: (Outcome) -> Void,
        before next: () async throws -> Value
    ) async rethrows -> Value {
        record(run(state: state, isEligible: isEligible))
        return try await next()
    }
}
