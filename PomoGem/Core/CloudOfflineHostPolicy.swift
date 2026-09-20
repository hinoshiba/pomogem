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

/// The launch presentations the split dataset-lineage taxonomy maps onto. The
/// launch host wiring lands in a separate step; until then every new case
/// reaches the generic blocked screen through the host's existing `default`
/// arm, which keeps the offline route and never performs a destructive action.
enum CloudDatasetLineageBlock: Equatable, Sendable {
    case remoteDatasetOffer, lineageUnavailable, environmentMismatch, localLedgerMissing
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
             StorageTransferRuntimeError.datasetRefreshRequired,
             // The four states split out of `datasetRefreshRequired`. All of
             // them still mean "a storage transfer decision is outstanding",
             // so the offline fallback offer is unchanged.
             StorageTransferRuntimeError.datasetReplacedRemotely,
             StorageTransferRuntimeError.cloudLineageUnavailable,
             StorageTransferRuntimeError.localLedgerMissing,
             StorageTransferRuntimeError.cloudEnvironmentMismatch: .storageTransfer
        case CloudActivityHistoryPreflightError.offlineHistoryChanged: .resetHistory
        default: nil
        }
    }

    /// Which launch presentation a dataset-lineage refusal deserves once the
    /// launch host is wired to the split taxonomy. Kept here, as a pure
    /// function, so the host change is a lookup rather than a second copy of
    /// the classification. `leftoverLocalStores` is deliberately absent: it is
    /// a Settings-time precondition, not a launch-time lineage decision.
    static func datasetLineageBlock(for error: Error) -> CloudDatasetLineageBlock? {
        switch error {
        // A real, terminal, generation-carrying control exists, so the host can
        // offer 「iCloudから再取得」 and the device -> iCloud overwrite.
        case StorageTransferRuntimeError.datasetReplacedRemotely: .remoteDatasetOffer
        // No lineage exists to refresh from. Offering a refresh here is the
        // dead end the user actually hit: the only honest choices are starting
        // a lineage from this device, or staying offline.
        case StorageTransferRuntimeError.cloudLineageUnavailable: .lineageUnavailable
        case StorageTransferRuntimeError.cloudEnvironmentMismatch: .environmentMismatch
        case StorageTransferRuntimeError.localLedgerMissing: .localLedgerMissing
        default: nil
        }
    }

    /// Explicit online retry changes only the preferred launch route. It does
    /// not permit .none after a mirror or bypass the usual online preflights.
    static func prefersOfflineLaunch(explicitOnlineRetry: Bool, requestedOfflineFallback: Bool,
                                     networkIsOffline: Bool?) -> Bool {
        !explicitOnlineRetry && (requestedOfflineFallback || networkIsOffline == true)
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
    static func timeoutRecoveryAction(
        cloudMirrorWasOpened: Bool,
        hasExistingStore: Bool,
        containersRetired: Bool,
        sceneIsActive: Bool
    ) -> CloudLaunchTimeoutRecoveryAction {
        if cloudMirrorWasOpened { return .retryOnline }
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
             .permission, .accountChanged, .unknown:
            return false
        }
    }

    /// Only a positive account result revokes local access. Ambiguous transport,
    /// record/schema errors and cancellation cannot be promoted into identity
    /// evidence merely because their descriptions mention an account.
    static func revocationReason(for error: Error) -> CloudOfflineRevocationReason? {
        if case AppleAccountBoundaryResolutionError.blocked(.accountMismatch) = error {
            return .accountMismatch
        }
        guard let failure = accountFailure(in: error) else { return nil }
        switch failure.kind {
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .accountChanged: return .accountChanged
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
