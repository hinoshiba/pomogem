import Foundation

enum CloudOfflineMountDecision: Equatable, Sendable {
    case allow, relaunchRequired, awaitContainerRetirement
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
