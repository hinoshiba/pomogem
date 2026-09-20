import CloudKit
import Darwin
import Foundation
import SwiftData

enum StorageTransferRuntimeError: Error, LocalizedError, Equatable {
    case relaunchRequired, remoteRecoveryRequired, datasetRefreshRequired
    case cloudCopyStillPending, recoveryNeedsReview

    var errorDescription: String? {
        switch self {
        case .relaunchRequired:
            "データを安全に切り替えるため、アプリを一度終了し、もう一度開いてください。アプリ自体は削除しないでください。"
        case .remoteRecoveryRequired:
            "iCloudで未完了のデータ切り替えが見つかりました。復旧が完了するまで通常の同期を停止しています。"
        case .datasetRefreshRequired:
            "別の端末でiCloudデータが置き換えられました。この端末の古いデータを送信しないよう同期を停止しています。"
        case .cloudCopyStillPending:
            "iCloudの全データと端末のコピーがまだ一致しません。通信を確認して再試行してください。"
        case .recoveryNeedsReview:
            "中断時のデータを安全に自動復旧できません。復旧用コピーを保護し、削除を停止しています。"
        }
    }
}

enum StorageTransferRetainedCancellationAdmission {
    static func validate(journal: StorageTransferJournal,
                         checkpoint: StorageTransferRuntimeCheckpoint,
                         currentProcessID: UUID, cloudMirrorWasOpened: Bool,
                         selection: PersistenceDeploymentSelectionState) throws {
        try checkpoint.validate(journal: journal)
        guard journal.retainsImportOnCancellation,
              selection == .selected(journal.source) else { throw StorageTransferError.staleTransaction }
        guard !cloudMirrorWasOpened,
              checkpoint.requestingProcessID != currentProcessID,
              checkpoint.verifiedCloudProcessID != currentProcessID else {
            throw StorageTransferRuntimeError.relaunchRequired
        }
    }
}

enum StorageTransferResumeOutcome: Equatable {
    case noPending, completed, cancelledRetainingImport
}

/// Runtime effects are only entered behind the launch host's scene/account
/// lease. A process that has opened a cloud mirror cannot erase a zone or move
/// its SQLite files. A fresh launch is an explicit part of this transfer flow.
@MainActor
final class StorageTransferRuntime {
    private static let processID = UUID()
    private let store: StorageTransferJournalStore
    private let root: URL
    /// The directory this feature owns. Exposed so a small state file that
    /// belongs beside `admission-*.json` can be built without widening the
    /// runtime's surface any further.
    var featureRoot: URL { root }
    private let releasePolicy: StorageTransferReleasePolicy
    private let storeDirectory: URL?
    private let readSourceSelection: @MainActor () -> PersistenceDeploymentSelectionState

    init(store: StorageTransferJournalStore, root: URL,
         releasePolicy: StorageTransferReleasePolicy = .standard,
         storeDirectory: URL? = nil,
         readSourceSelection: @escaping @MainActor () -> PersistenceDeploymentSelectionState = {
             PersistenceDeploymentState.load()
         }) {
        self.store = store
        self.root = root
        self.releasePolicy = releasePolicy
        self.storeDirectory = storeDirectory
        self.readSourceSelection = readSourceSelection
    }

    static func live() throws -> StorageTransferRuntime {
        try live(releasePolicy: .standard)
    }

    #if DEBUG
    static func liveForIsolatedTesting() throws -> StorageTransferRuntime {
        try live(releasePolicy: .isolatedTesting)
    }
    #endif

    private static func live(releasePolicy: StorageTransferReleasePolicy) throws -> StorageTransferRuntime {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return Self(store: try .live(), root: support.appendingPathComponent("StorageTransfer", isDirectory: true),
                    releasePolicy: releasePolicy)
    }

    func pendingLocalJournal() throws -> StorageTransferJournal? { try store.load() }

    /// A local receipt of a prior preflight; callers still need a fresh remote
    /// check before authorizing a CloudKit mirror.
    func localDatasetAdmission(binding: ActiveAccountLocalBinding) throws -> StorageTransferDatasetAdmission? {
        let value = try admissionFile(binding).load()
        guard value == nil || value?.binding == binding else { throw StorageTransferError.staleTransaction }
        return value
    }

    func pendingRemoteCancellationIntent() throws -> StorageTransferRemoteCancellationIntent? {
        try remoteCancellation().pendingIntent()
    }

    func resumeRemoteCancellation(validateAccess: @escaping @MainActor () throws -> Void) async throws {
        guard let intent = try pendingRemoteCancellationIntent() else { return }
        let lease = StorageTransferAccountLease(center: .default)
        defer { lease.stop() }
        let validate: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            try lease.check()
            try validateAccess()
        }
        _ = try await AppleAccountBoundaryResolver().resolve(expectedBinding: intent.binding)
        try validate()
        try await remoteCancellation().resume(expectedBinding: intent.binding,
            recovery: remote(validate), validateAccess: validate)
    }

    func remoteRecoveryStatus(binding: ActiveAccountLocalBinding,
                              validateAccess: @escaping @MainActor () throws -> Void) async throws -> StorageTransferRecoveryControl? {
        try await remote(validateAccess).inspect(accountFingerprint: binding.accountFingerprint)?.control
    }

    func preflightCloudMount(binding: ActiveAccountLocalBinding,
                             controlClient: StorageTransferCloudMountControlClient? = nil,
                             accountDefaults: UserDefaults = .standard,
                             validateAccess: @escaping @MainActor () throws -> Void) async throws {
        let reader = StorageTransferCloudMountControlReader(client: controlClient,
            defaults: accountDefaults, transferJournalStore: store)
        try await preflightCloudMount(binding: binding, readControl: {
            try await reader.read(expectedBinding: binding, validateAccess: validateAccess)
        }, validateAccess: validateAccess)
    }

    /// The transport seam preserves the actual local admission files and final
    /// gate. A cancellation intent accepted during either remote read cannot
    /// authorize a container just because the remote control stayed unchanged.
    func preflightCloudMount(binding: ActiveAccountLocalBinding,
                             readControl: @escaping @MainActor () async throws -> StorageTransferRecoveryControl?,
                             validateAccess: @escaping @MainActor () throws -> Void) async throws {
        let validate: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            try validateAccess()
            try self.requireNoPendingRemoteCancellation()
            guard try self.store.load() == nil else { throw StorageTransferRuntimeError.remoteRecoveryRequired }
        }
        try validate()
        let status = try await readControl()
        try validate()
        try validateControlAccount(status, binding: binding)
        guard status?.blocksWriters != true else { throw StorageTransferRuntimeError.remoteRecoveryRequired }
        let file = try admissionFile(binding)
        let expected = StorageTransferDatasetAdmission(binding: binding, datasetGenerationID: status?.datasetGenerationID)
        if let found = try file.load() {
            guard found == expected else { throw StorageTransferRuntimeError.datasetRefreshRequired }
        } else {
            // An old cache can join the legacy dataset only. After a remotely
            // committed replacement, only an actually absent cache may enroll.
            if expected.datasetGenerationID != nil {
                try requireNoArtifacts(selection: .cloud(binding: binding))
            }
            try validate()
            try file.save(expected, replacing: nil)
        }
        let after = try await readControl()
        try validate()
        try validateControlAccount(after, binding: binding)
        guard after == status else { throw StorageTransferRuntimeError.remoteRecoveryRequired }
    }

    /// Explicitly confirmed refresh of an obsolete cache. Only the same
    /// account's displayed committed generation can authorize this request.
    func refreshCloudDataset(binding: ActiveAccountLocalBinding, expectedGenerationID: UUID,
                             validateAccess: @escaping @MainActor () throws -> Void) async throws {
        try await refreshCloudDataset(binding: binding, expectedGenerationID: expectedGenerationID,
            verifyAccount: {
                try await AppleAccountBoundaryResolver().resolve(expectedBinding: binding).binding
            }, readControl: {
                try await self.remoteRecoveryStatus(binding: binding, validateAccess: validateAccess)
            }, validateAccess: validateAccess)
    }

    func refreshCloudDataset(binding: ActiveAccountLocalBinding, expectedGenerationID: UUID,
                             verifyAccount: @escaping @MainActor () async throws -> ActiveAccountLocalBinding,
                             readControl: @escaping @MainActor () async throws -> StorageTransferRecoveryControl?,
                             validateAccess: @escaping @MainActor () throws -> Void) async throws {
        let validate: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            try validateAccess()
            try self.requireNoPendingRemoteCancellation()
            guard try self.store.load() == nil, !StorageTransferProcessState.cloudMirrorWasOpened else {
                throw StorageTransferRuntimeError.relaunchRequired
            }
        }
        try validate()
        let verifiedBinding = try await verifyAccount()
        try validate()
        guard verifiedBinding == binding else { throw StorageTransferRecoveryError.identityMismatch }
        let status = try await readControl()
        try validate()
        try validateControlAccount(status, binding: binding)
        guard let status, !status.blocksWriters, status.datasetGenerationID == expectedGenerationID,
              let destinationBinding = ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                  accountFingerprint: binding.accountFingerprint) else { throw StorageTransferError.staleTransaction }
        let journal = try StorageTransferJournal(choice: .enableCloudKeepingCloud,
            source: .cloud(binding: binding), destination: .cloud(binding: destinationBinding),
            cloudBinding: destinationBinding)
        try requireNoArtifacts(selection: journal.destination)
        try cleanup().requireCapacityForNewTransfer(transactionID: journal.transactionID, mayCreateRemotePayload: false)
        let file = try checkpointFile(files(journal))
        var checkpoint = StorageTransferRuntimeCheckpoint(transactionID: journal.transactionID,
            requestingProcessID: Self.processID)
        checkpoint.didObserveBaselineControl = true
        checkpoint.baselineControl = status
        try file.save(checkpoint, replacing: nil)
        let after = try await readControl()
        try validate()
        try validateControlAccount(after, binding: binding)
        guard after == status else { throw StorageTransferError.staleTransaction }
        try validate()
        try store.begin(journal)
    }

    /// Explicitly confirmed replacement of the current iCloud dataset with this
    /// device's data - the opposite direction of `refreshCloudDataset`, and the
    /// only way a device that is already bound to the account but fenced out of
    /// the current generation can publish its own records. Only the same
    /// account's displayed committed generation can authorize this request.
    func overwriteCloudDataset(binding: ActiveAccountLocalBinding, expectedGenerationID: UUID,
                               validateAccess: @escaping @MainActor () throws -> Void) async throws {
        try await overwriteCloudDataset(binding: binding, expectedGenerationID: expectedGenerationID,
            verifyAccount: {
                try await AppleAccountBoundaryResolver().resolve(expectedBinding: binding).binding
            }, readControl: {
                try await self.remoteRecoveryStatus(binding: binding, validateAccess: validateAccess)
            }, validateAccess: validateAccess)
    }

    /// A clone of `refreshCloudDataset` with the same seams and the same two
    /// read control discipline. Exactly three differences, each marked below.
    func overwriteCloudDataset(binding: ActiveAccountLocalBinding, expectedGenerationID: UUID,
                               verifyAccount: @escaping @MainActor () async throws -> ActiveAccountLocalBinding,
                               readControl: @escaping @MainActor () async throws -> StorageTransferRecoveryControl?,
                               validateAccess: @escaping @MainActor () throws -> Void) async throws {
        // DIFFERENCE 1: the release gate is the FIRST statement, before any
        // file is created, any account is resolved and any remote call is made.
        try releasePolicy.validate(.overwriteCloudFromDevice)
        let validate: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            try validateAccess()
            try self.requireNoPendingRemoteCancellation()
            guard try self.store.load() == nil, !StorageTransferProcessState.cloudMirrorWasOpened else {
                throw StorageTransferRuntimeError.relaunchRequired
            }
        }
        try validate()
        let verifiedBinding = try await verifyAccount()
        try validate()
        guard verifiedBinding == binding else { throw StorageTransferRecoveryError.identityMismatch }
        let status = try await readControl()
        try validate()
        try validateControlAccount(status, binding: binding)
        guard let status, !status.blocksWriters, status.datasetGenerationID == expectedGenerationID,
              let destinationBinding = ActiveAccountLocalBinding(namespace: AccountDataNamespace(),
                  accountFingerprint: binding.accountFingerprint) else { throw StorageTransferError.staleTransaction }
        // DIFFERENCE 2: the divergent device cache is the source and its data
        // becomes the new generation, so this choice replaces the cloud dataset.
        let journal = try StorageTransferJournal(choice: .overwriteCloudFromDevice,
            source: .cloud(binding: binding), destination: .cloud(binding: destinationBinding),
            cloudBinding: destinationBinding)
        try requireNoArtifacts(selection: journal.destination)
        // DIFFERENCE 3: unlike a refresh, this transaction stages a recovery
        // copy of the device payload on the server before anything is deleted.
        try cleanup().requireCapacityForNewTransfer(transactionID: journal.transactionID, mayCreateRemotePayload: true)
        let file = try checkpointFile(files(journal))
        var checkpoint = StorageTransferRuntimeCheckpoint(transactionID: journal.transactionID,
            requestingProcessID: Self.processID)
        checkpoint.didObserveBaselineControl = true
        checkpoint.baselineControl = status
        try file.save(checkpoint, replacing: nil)
        let after = try await readControl()
        try validate()
        try validateControlAccount(after, binding: binding)
        guard after == status else { throw StorageTransferError.staleTransaction }
        try validate()
        try store.begin(journal)
    }

    private func validateControlAccount(_ control: StorageTransferRecoveryControl?,
                                        binding: ActiveAccountLocalBinding) throws {
        try control?.validate()
        guard control == nil || control?.manifest.accountFingerprint == binding.accountFingerprint else {
            throw StorageTransferRecoveryError.identityMismatch
        }
    }

    /// Saves the explicit user choice before normal writers are unmounted.
    /// Source-cloud requests first prove a complete server/local comparison.
    func begin(choice: StorageTransferChoice, source: PersistenceDeploymentSelection,
               sourceContext: ModelContext,
               validateAccess: @escaping @MainActor () throws -> Void) async throws {
        try validateAccess()
        try releasePolicy.validate(choice)
        try requireNoPendingRemoteCancellation()
        guard try store.load() == nil, !sourceContext.hasChanges,
              try FocusCloudSyncStore.canonicalActive(context: sourceContext) == nil else {
            throw StorageTransferError.activeTimer
        }
        let binding: ActiveAccountLocalBinding
        let destination: PersistenceDeploymentSelection
        switch (choice, source) {
        case let (.disableCloudKeepingCopy, .cloud(current)):
            binding = try await AppleAccountBoundaryResolver().resolve(expectedBinding: current).binding
            destination = .localOnly(namespace: AccountDataNamespace())
            try await requireStableCloudCopy(context: sourceContext, binding: binding, validate: validateAccess)
        case (.enableCloudKeepingCloud, .localOnly), (.enableCloudReplacingCloud, .localOnly):
            binding = try await AppleAccountBoundaryResolver().resolve().binding
            destination = .cloud(binding: binding)
        default: throw StorageTransferError.invalidJournal
        }
        try validateAccess()
        guard try FocusCloudSyncStore.canonicalActive(context: sourceContext) == nil else { throw StorageTransferError.activeTimer }
        let control = try await remoteRecoveryStatus(binding: binding, validateAccess: validateAccess)
        guard control?.blocksWriters != true else { throw StorageTransferRuntimeError.remoteRecoveryRequired }
        try requireNoArtifacts(selection: destination)
        let journal = try StorageTransferJournal(choice: choice, source: source,
            destination: destination, cloudBinding: binding)
        try cleanup().requireCapacityForNewTransfer(transactionID: journal.transactionID,
            mayCreateRemotePayload: journal.choice.replacesCloud)
        let files = try files(journal)
        let checkpoint = try checkpointFile(files)
        var initialCheckpoint = StorageTransferRuntimeCheckpoint(transactionID: journal.transactionID,
            requestingProcessID: Self.processID)
        initialCheckpoint.didObserveBaselineControl = true
        initialCheckpoint.baselineControl = control
        try checkpoint.save(initialCheckpoint, replacing: nil)
        try validateAccess()
        guard !sourceContext.hasChanges,
              try FocusCloudSyncStore.canonicalActive(context: ModelContext(sourceContext.container)) == nil else {
            throw StorageTransferError.activeTimer
        }
        try requireNoPendingRemoteCancellation()
        try store.begin(journal)
    }

    @discardableResult
    func resumePendingTransfer(validateAccess: @escaping @MainActor () throws -> Void,
                               trackContainer: @escaping @MainActor (ModelContainer, Bool) -> Void) async throws -> StorageTransferResumeOutcome {
        try requireNoPendingRemoteCancellation()
        guard let initial = try store.load() else { return .noPending }
        try initial.validate()
        // A durable cancellation is an accepted request, even if the process
        // ended before clearing pending-v1. Never resume import or promotion
        // behind that request, and never reinterpret a different journal.
        if let retained = try cleanup().retainedCancellationJournal(transactionID: initial.transactionID) {
            guard retained == initial,
                  try cancelRetainingImportIfApplicable(expectedTransactionID: initial.transactionID,
                                                        validateAccess: validateAccess) else {
                throw StorageTransferError.staleTransaction
            }
            return .cancelledRetainingImport
        }
        // Preserve every checkpoint and backup. Even a same-transaction resume
        // on another installation must not reach zone deletion or promotion.
        try releasePolicy.validate(initial.choice)
        let files = try files(initial)
        let saved = try checkpoint(files, journal: initial)
        guard saved.requestingProcessID != Self.processID,
              !StorageTransferProcessState.cloudMirrorWasOpened else { throw StorageTransferRuntimeError.relaunchRequired }
        let lease = StorageTransferAccountLease(center: .default)
        defer { lease.stop() }
        let validate: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            try lease.check()
            try validateAccess()
            guard try self.store.load()?.transactionID == initial.transactionID else { throw StorageTransferError.staleTransaction }
        }
        _ = try await AppleAccountBoundaryResolver().resolve(expectedBinding: initial.cloudBinding)
        try validate()
        let effects = StorageTransferEffects(
            captureSource: { journal in
                try await self.withAuthority(journal, validate: validate) { try await self.captureSource(journal, validate: validate) }
            },
            saveRemoteRecovery: { journal in
                try await self.withAuthority(journal, validate: validate) { try await self.saveRecovery(journal, validate: validate) }
            },
            prepareDestination: { journal in
                try await self.withAuthority(journal, validate: validate) {
                    try await self.prepareDestination(journal, validate: validate, track: trackContainer)
                }
            },
            verifyDestination: { journal in
                try await self.withAuthority(journal, validate: validate) { try await self.verifyDestination(journal, validate: validate) }
            },
            promoteDestination: { journal in
                try await self.withAuthority(journal, validate: validate) { try await self.promote(journal, validate: validate) }
            },
            retireSource: { journal in
                try validate()
                guard !StorageTransferProcessState.cloudMirrorWasOpened else { throw StorageTransferRuntimeError.relaunchRequired }
                try StorageTransferPersistence.requireAllReleased()
                if try self.checkpoint(self.files(journal), journal: journal).recoveredFromServer {
                    try self.requireNoArtifacts(selection: journal.source)
                } else {
                    try self.files(journal).retireSource(selection: journal.source)
                }
            }, enqueueCleanup: { journal in
                try validate()
                let manifest = try self.checkpoint(self.files(journal), journal: journal).recoveryManifest
                try self.cleanup().enqueue(journal: journal, recoveryManifest: manifest)
            })
        try await StorageTransferCoordinator(store: store, effects: effects).resume(
            transactionID: initial.transactionID, validateTransfer: validate)
        try resumeLocalCleanup(validateAccess: validateAccess)
        return .completed
    }

    /// Best-effort remote garbage collection runs after the verified cloud
    /// session is visible. Its finite deadline never delays ordinary launch.
    func retryRemoteCleanup(binding: ActiveAccountLocalBinding,
                            validateAccess: @escaping @MainActor @Sendable () throws -> Void) async throws -> StorageTransferCleanupRetryResult {
        try validateAccess()
        guard try store.load() == nil else { return StorageTransferCleanupRetryResult() }
        let cleanup = try cleanup()
        let recovery = remote(validateAccess)
        return try await withThrowingTaskGroup(of: StorageTransferCleanupRetryResult.self) { group in
            group.addTask { @MainActor in
                try await cleanup.retryRemoteCleanup(expectedBinding: binding, recovery: recovery,
                    validateAccess: validateAccess)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    func resumeLocalCleanup(validateAccess: @escaping @MainActor () throws -> Void) throws {
        try validateAccess()
        guard try store.load() == nil else { return }
        let cleanup = try cleanup()
        for receipt in try cleanup.pendingReceipts() where !receipt.localRemoved {
            try validateAccess()
            try cleanup.runLocal(transactionID: receipt.transactionID)
        }
    }

    func cancelPendingTransfer(expectedTransactionID: UUID,
                               validateAccess: @escaping @MainActor () throws -> Void) async throws {
        if try cancelRetainingImportIfApplicable(expectedTransactionID: expectedTransactionID,
                                                 validateAccess: validateAccess) { return }
        guard let journal = try store.load(), journal.transactionID == expectedTransactionID,
              journal.permitsCancellation else { throw StorageTransferError.staleTransaction }
        let lease = StorageTransferAccountLease(center: .default)
        defer { lease.stop() }
        let validate: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            try lease.check()
            try validateAccess()
        }
        _ = try await AppleAccountBoundaryResolver().resolve(expectedBinding: journal.cloudBinding)
        try await cancelPendingTransfer(expectedTransactionID: expectedTransactionID,
            recovery: remote(validate), validateAccess: validate)
    }

    /// The injectable remote boundary exercises the same durable cancellation
    /// path as production, including an unacknowledged staging CAS and retries
    /// after another device has advanced control-v1.
    func cancelPendingTransfer(expectedTransactionID: UUID, recovery: StorageTransferRemoteRecovery,
                               validateAccess: @escaping @MainActor () throws -> Void) async throws {
        if try cancelRetainingImportIfApplicable(expectedTransactionID: expectedTransactionID,
                                                 validateAccess: validateAccess) { return }
        guard var journal = try store.load(), journal.transactionID == expectedTransactionID,
              journal.permitsCancellation else { throw StorageTransferError.staleTransaction }
        let files = try files(journal)
        var saved = try checkpoint(files, journal: journal)
        let cleanup = try cleanup()
        try cleanup.requireCapacityForNewTransfer(transactionID: expectedTransactionID,
            mayCreateRemotePayload: journal.choice.replacesCloud)
        let validate: @MainActor () throws -> Void = {
            try Task.checkCancellation()
            try validateAccess()
            guard try self.store.load() == journal else { throw StorageTransferError.staleTransaction }
        }
        let recovery = recovery.withAdditionalValidation(validate)
        var cancelled: StorageTransferRecoveryControl?
        if journal.choice.replacesCloud, journal.phase >= .sourceSaved || saved.recoveredFromServer {
            let payload = StorageTransferPayloadStore(files: files)
            // A restored request already owns a verified remote payload, but
            // may have crashed before the coordinator acknowledged sourceSaved.
            if journal.phase == .requested {
                guard saved.recoveredFromServer,
                      let receipt = try payload.acknowledgedReceipt(),
                      saved.baselineControl?.manifest.transactionID == expectedTransactionID,
                      saved.baselineControl?.manifest.payloadSHA256 == receipt.sha256 else {
                    throw StorageTransferError.invalidJournal
                }
                _ = try payload.load(expectedDigest: receipt.sha256)
                let next = try journal.advancing(to: .sourceSaved, sourceDigest: receipt.sha256)
                try validate()
                try store.save(next, replacing: journal)
                journal = next
            }
            guard let digest = journal.sourceDigest else { throw StorageTransferError.invalidJournal }
            let bytes = try payload.bytes(expectedDigest: digest)
            let manifest: StorageTransferRecoveryManifest
            if let existing = saved.recoveryManifest { manifest = existing }
            else if saved.recoveredFromServer, let original = saved.baselineControl?.manifest { manifest = original }
            else {
                manifest = try StorageTransferRecoveryManifest(transactionID: expectedTransactionID,
                    accountFingerprint: journal.cloudBinding.accountFingerprint, payload: bytes,
                    previousDatasetGenerationID: saved.baselineControl?.datasetGenerationID)
            }
            try manifest.validate(payload: bytes)
            guard manifest.transactionID == expectedTransactionID,
                  manifest.accountFingerprint == journal.cloudBinding.accountFingerprint else {
                throw StorageTransferError.staleTransaction
            }
            if saved.recoveryManifest == nil {
                let previous = saved
                saved.recoveryManifest = manifest
                try saved.validate(journal: journal)
                try validate()
                try checkpointFile(files).save(saved, replacing: previous)
            }
            if let archived = try await recovery.archivedCancelledControl(manifest: manifest) {
                cancelled = archived
            } else {
                let predecessor = saved.baselineControl?.isTerminal == true
                    ? saved.baselineControl?.manifest.transactionID : nil
                cancelled = try await recovery.cancelUnclaimed(manifest: manifest,
                    replacingTerminalTransactionID: predecessor).envelope.control
            }
            try validate()
        }
        // The terminal fence prevents late staging creates. The durable retry
        // queue survives local cancellation and repeats exact chunk cleanup,
        // because a previously submitted chunk may still arrive afterward.
        try validate()
        try cleanup.enqueueCancellation(journal: journal, cancelledControl: cancelled)
        try validate()
        try store.cancel(journal)
    }

    /// Abandon only the local request, retaining its complete import tree. This
    /// synchronous path neither opens a container nor contacts iCloud; the next
    /// source mount still needs its ordinary account and dataset admission.
    private func cancelRetainingImportIfApplicable(expectedTransactionID: UUID,
                                                  validateAccess: @escaping @MainActor () throws -> Void) throws -> Bool {
        try Task.checkCancellation()
        try validateAccess()
        if try acknowledgeRetainedCancellation(expectedTransactionID: expectedTransactionID,
                                               validateAccess: validateAccess) { return true }
        guard let journal = try store.load(), journal.retainsImportOnCancellation else { return false }
        guard journal.transactionID == expectedTransactionID else { throw StorageTransferError.staleTransaction }
        let files = try files(journal)
        let saved = try checkpoint(files, journal: journal)
        let cleanup = try cleanup()
        let validate = {
            try Task.checkCancellation()
            try validateAccess()
            guard try self.store.load() == journal,
                  try self.checkpoint(files, journal: journal) == saved else {
                throw StorageTransferError.staleTransaction
            }
            try self.validateRetainedCancellation(journal: journal, checkpoint: saved, files: files)
        }
        try validate()
        try cleanup.requireCapacityForNewTransfer(transactionID: expectedTransactionID, mayCreateRemotePayload: false)
        _ = try cleanup.enqueueCancellation(journal: journal, cancelledControl: nil)
        try validate()
        try store.cancel(journal)
        return true
    }

    /// A lost local reply can be retried, but never consume a later pending
    /// transaction or authorize a different source selection.
    private func acknowledgeRetainedCancellation(expectedTransactionID: UUID,
                                                 validateAccess: () throws -> Void) throws -> Bool {
        guard try store.load() == nil,
              let journal = try cleanup().retainedCancellationJournal(transactionID: expectedTransactionID) else {
            return false
        }
        try validateAccess()
        try Task.checkCancellation()
        let files = try files(journal)
        try validateRetainedCancellation(journal: journal,
            checkpoint: checkpoint(files, journal: journal), files: files)
        guard try store.load() == nil else { throw StorageTransferError.staleTransaction }
        return true
    }

    private func validateRetainedCancellation(journal: StorageTransferJournal,
                                              checkpoint: StorageTransferRuntimeCheckpoint,
                                              files: StorageTransferStoreFiles) throws {
        try requireNoPendingRemoteCancellation()
        try StorageTransferRetainedCancellationAdmission.validate(journal: journal, checkpoint: checkpoint,
            currentProcessID: Self.processID, cloudMirrorWasOpened: StorageTransferProcessState.cloudMirrorWasOpened,
            selection: readSourceSelection())
        if let committed = try store.committedSelection() {
            guard committed.selection == journal.source, committed.transactionID != journal.transactionID else {
                throw StorageTransferError.staleTransaction
            }
        }
        try StorageTransferPersistence.requireAllReleased()
        try files.requireUnchangedFrozenSource(selection: journal.source)
    }

    func cancelRemoteTransfer(binding: ActiveAccountLocalBinding, expectedTransactionID: UUID,
                              validateAccess: @escaping @MainActor () throws -> Void) async throws {
        if let intent = try pendingRemoteCancellationIntent() {
            guard intent.transactionID == expectedTransactionID, intent.binding == binding else {
                throw StorageTransferError.staleTransaction
            }
            try await resumeRemoteCancellation(validateAccess: validateAccess)
            return
        }
        if let localJournal = try store.load() {
            guard localJournal.transactionID == expectedTransactionID, localJournal.permitsCancellation,
                  localJournal.cloudBinding == binding else { throw StorageTransferError.staleTransaction }
            try await cancelPendingTransfer(expectedTransactionID: expectedTransactionID, validateAccess: validateAccess)
            return
        }
        guard let control = try await remoteRecoveryStatus(binding: binding, validateAccess: validateAccess) else {
            throw StorageTransferError.staleTransaction
        }
        guard control.manifest.transactionID == expectedTransactionID else { throw StorageTransferError.staleTransaction }
        try validateAccess()
        try remoteCancellation().accept(binding: binding, expectedTransactionID: expectedTransactionID,
            observedControl: control, validateAccess: validateAccess)
        try await resumeRemoteCancellation(validateAccess: validateAccess)
    }

    func recoverRemoteTransfer(binding: ActiveAccountLocalBinding, expectedTransactionID: UUID,
                               validateAccess: @escaping @MainActor () throws -> Void) async throws {
        try validateAccess()
        // Refuse a closed resume bit before any remote read, then refuse again
        // on the observed phase below: the phase, not the kind, is the gate.
        try releasePolicy.requireRemoteResumeIsPublished()
        try requireNoPendingRemoteCancellation()
        guard !StorageTransferProcessState.cloudMirrorWasOpened else { throw StorageTransferRuntimeError.relaunchRequired }
        if let journal = try store.load() {
            guard journal.transactionID == expectedTransactionID,
                  journal.cloudBinding == binding else { throw StorageTransferError.staleTransaction }
            return
        }
        let recovery = remote(validateAccess)
        guard let control = try await remoteRecoveryStatus(binding: binding, validateAccess: validateAccess),
              control.manifest.transactionID == expectedTransactionID, control.blocksWriters else {
            throw StorageTransferError.staleTransaction
        }
        // Only .staging / .backupVerified may be adopted. The backupVerified ->
        // replacing CAS elects exactly one executor of the zone deletion, so a
        // later arrival observing .replacing is refused rather than becoming a
        // second executor (Docs/MultiDeviceCloudSafety.md defect 2).
        try releasePolicy.validateRemoteResume(control.phase)
        let recovered = try await recovery.recover(manifest: control.manifest)
        try validateAccess()
        let snapshot = try JSONDecoder().decode(PomoGemStorageSnapshot.self, from: recovered.bytes)
        try snapshot.validate()
        // A server-only recovery owns no previous on-device source store.
        // Its immutable all-model payload is the source, including local-only
        // legacy rows. Never invent a path to another installation's cache.
        let source = PersistenceDeploymentSelection.localOnly(namespace: AccountDataNamespace())
        let journal = try StorageTransferJournal(transactionID: expectedTransactionID,
            choice: .overwriteCloudFromDevice, source: source,
            destination: .cloud(binding: binding), cloudBinding: binding)
        try requireNoArtifacts(selection: source)
        try requireNoArtifacts(selection: journal.destination)
        let files = try files(journal)
        try cleanup().requireCapacityForNewTransfer(transactionID: expectedTransactionID, mayCreateRemotePayload: true)
        _ = try StorageTransferPayloadStore(files: files).saveRecovered(recovered.bytes, manifest: control.manifest)
        let stateFile = try checkpointFile(files)
        if let previous = try stateFile.load() {
            // This is an unfinished request before journal creation. Its exact
            // payload is retained; a new local-only source namespace is harmless
            // only while it has never owned any store files.
            guard previous.transactionID == expectedTransactionID, previous.recoveredFromServer,
                  previous.recoveryManifest == nil, previous.importedPayloadDigest == nil else {
                throw StorageTransferError.staleTransaction
            }
            var value = previous
            value.requestingProcessID = Self.processID
            value.didObserveBaselineControl = true
            value.baselineControl = control
            try stateFile.save(value, replacing: previous)
        } else {
            var value = StorageTransferRuntimeCheckpoint(transactionID: expectedTransactionID,
                requestingProcessID: Self.processID)
            value.recoveredFromServer = true
            value.didObserveBaselineControl = true
            value.baselineControl = control
            try stateFile.save(value, replacing: nil)
        }
        let after = try await remoteRecoveryStatus(binding: binding, validateAccess: validateAccess)
        guard after == recovered.envelope.control else { throw StorageTransferError.staleTransaction }
        try validateAccess()
        try requireNoPendingRemoteCancellation()
        try store.begin(journal)
    }

    private func captureSource(_ journal: StorageTransferJournal,
                               validate: @escaping @MainActor () throws -> Void) async throws -> String {
        let files = try files(journal)
        let payload = StorageTransferPayloadStore(files: files)
        if let receipt = try payload.acknowledgedReceipt() { return receipt.sha256 }
        try validate()
        let snapshot = try StorageTransferPersistence.snapshotFrozenSource(journal: journal, files: files)
        // S11. Deliberately skipped for both replacement kinds and for a
        // refresh: an overwrite exists precisely because this device's data has
        // diverged from the current iCloud dataset. Requiring equality here
        // would make the operation impossible, not safer.
        if journal.choice.requiresCloudEqualityOfFrozenSource {
            try await requireCloudEquals(snapshot, binding: journal.cloudBinding, validate: validate)
        }
        try validate()
        return try payload.save(snapshot).sha256
    }

    private func saveRecovery(_ journal: StorageTransferJournal,
                              validate: @escaping @MainActor () throws -> Void) async throws -> StorageTransferRecoveryManifest {
        try releasePolicy.validate(journal.choice)
        let files = try files(journal)
        guard let digest = journal.sourceDigest else { throw StorageTransferError.invalidJournal }
        let payload = try StorageTransferPayloadStore(files: files).bytes(expectedDigest: digest)
        var checkpoint = try checkpoint(files, journal: journal)
        let current = try await remote(validate).inspect(accountFingerprint: journal.cloudBinding.accountFingerprint)
        let manifest: StorageTransferRecoveryManifest
        if let existing = checkpoint.recoveryManifest { manifest = existing }
        else {
            if let current, current.control.manifest.transactionID == journal.transactionID {
                manifest = current.control.manifest
                try manifest.validate(payload: payload)
            } else {
                guard current?.control.blocksWriters != true else { throw StorageTransferRuntimeError.remoteRecoveryRequired }
                manifest = try StorageTransferRecoveryManifest(transactionID: journal.transactionID,
                    accountFingerprint: journal.cloudBinding.accountFingerprint, payload: payload,
                    previousDatasetGenerationID: current?.control.datasetGenerationID)
            }
            let previous = checkpoint
            checkpoint.recoveryManifest = manifest
            try validate()
            try checkpointFile(files).save(checkpoint, replacing: previous)
        }
        let predecessor = current?.control.isTerminal == true ? current?.control.manifest.transactionID : nil
        _ = try await remote(validate).stage(manifest: manifest, payload: payload, replacingTerminalTransactionID: predecessor)
        return manifest
    }

    private func prepareDestination(_ journal: StorageTransferJournal,
                                    validate: @escaping @MainActor () throws -> Void,
                                    track: @escaping @MainActor (ModelContainer, Bool) -> Void) async throws -> String {
        try releasePolicy.validate(journal.choice)
        let files = try files(journal)
        var checkpoint = try checkpoint(files, journal: journal)
        guard let digest = journal.sourceDigest else { throw StorageTransferError.invalidJournal }
        let source = try StorageTransferPayloadStore(files: files).load(expectedDigest: digest)
        if journal.choice == .disableCloudKeepingCopy {
            try await requireCloudEquals(source, binding: journal.cloudBinding, validate: validate)
            try importLocal(source, digest: digest, journal: journal, files: files, checkpoint: &checkpoint, track: track)
            return digest
        }
        if checkpoint.verifiedCloudProcessID != nil {
            guard checkpoint.verifiedCloudProcessID != Self.processID,
                  !StorageTransferProcessState.cloudMirrorWasOpened else { throw StorageTransferRuntimeError.relaunchRequired }
            let snapshot = try readStaged(journal, files: files)
            try await requireCloudEquals(snapshot, binding: journal.cloudBinding, validate: validate)
            if journal.choice.replacesCloud {
                guard try snapshot.isEquivalent(to: source, normalizeEmptyRelationships: true) else { throw StorageTransferError.snapshotMismatch }
                return digest
            }
            return try saveDestinationPayload(snapshot, files: files)
        }
        let expectedControl: StorageTransferRecoveryControl?
        if journal.choice.replacesCloud {
            guard let manifest = checkpoint.recoveryManifest else { throw StorageTransferError.recoveryCopyRequired }
            let recovery = remote(validate)
            let deletionStore = try StorageTransferManagedZoneDeletionFileStore(
                transactionDirectory: files.transactionDirectory, transactionID: journal.transactionID)
            if checkpoint.importedPayloadDigest == nil {
                guard !StorageTransferProcessState.cloudMirrorWasOpened else { throw StorageTransferRuntimeError.relaunchRequired }
                let status = try await recovery.inspect(accountFingerprint: journal.cloudBinding.accountFingerprint)
                let validateDeletion = {
                    try validate()
                    try StorageTransferPersistence.requireAllReleased()
                    guard !StorageTransferProcessState.cloudMirrorWasOpened else { throw StorageTransferRuntimeError.relaunchRequired }
                }
                if checkpoint.recoveredFromServer, status?.control.phase == .replacing {
                    if checkpoint.partialRecoveryAttemptID == nil {
                        let previous = checkpoint
                        checkpoint.partialRecoveryAttemptID = UUID()
                        try checkpointFile(files).save(checkpoint, replacing: previous)
                    }
                    guard let attemptID = checkpoint.partialRecoveryAttemptID else { throw StorageTransferError.invalidJournal }
                    let partial = StorageTransferPartialDestinationRecovery(
                        store: try StorageTransferPartialDestinationFileStore(transactionDirectory: files.transactionDirectory,
                            transactionID: journal.transactionID),
                        backend: StorageTransferPartialDestinationCloudKit(expectedBinding: journal.cloudBinding,
                            validateAccess: validate),
                        recovery: recovery, validateGenerationAndQuiescence: validateDeletion)
                    _ = try await partial.prepare(attemptID: attemptID, manifest: manifest)
                    _ = try await partial.resume(attemptID: attemptID, manifest: manifest)
                } else {
                    let backend = StorageTransferManagedZoneDeletionCloudKit(expectedBinding: journal.cloudBinding, validateAccess: validate)
                    let deletion = StorageTransferManagedZoneDeletion(store: deletionStore, backend: backend,
                        recovery: recovery, validateGenerationAndQuiescence: validateDeletion)
                    if try deletionStore.load() == nil {
                        let baseline = try await backend.readSnapshot()
                        try deletion.persistPlan(StorageTransferManagedZoneDeletionPlan(manifest: manifest, baseline: baseline))
                    }
                    let permission = try await recovery.authorizeReplacement(manifest: manifest)
                    _ = try await deletion.run(transactionID: journal.transactionID, recoveryReceipt: permission)
                }
                try validate()
                try importLocal(source, digest: digest, journal: journal, files: files, checkpoint: &checkpoint, track: track)
            }
            expectedControl = try await recovery.inspect(accountFingerprint: journal.cloudBinding.accountFingerprint)?.control
            guard expectedControl?.manifest == manifest, expectedControl?.phase == .replacing else {
                throw StorageTransferRuntimeError.remoteRecoveryRequired
            }
        } else {
            expectedControl = try await remoteRecoveryStatus(binding: journal.cloudBinding, validateAccess: validate)
            guard expectedControl?.blocksWriters != true else { throw StorageTransferRuntimeError.remoteRecoveryRequired }
        }
        try validate()
        if journal.choice.replacesCloud, !checkpoint.cloudExportIntentRecorded {
            let beforeExport = try await CloudStorageTransferCloudKit().readSnapshot(
                expectedBinding: journal.cloudBinding, validateTransfer: validate)
            guard beforeExport.zones.isEmpty, beforeExport.snapshot.records.isEmpty else {
                throw StorageTransferRuntimeError.recoveryNeedsReview
            }
            let latestControl = try await remoteRecoveryStatus(binding: journal.cloudBinding, validateAccess: validate)
            guard latestControl == expectedControl else { throw StorageTransferRuntimeError.remoteRecoveryRequired }
            let previous = checkpoint
            checkpoint.cloudExportIntentRecorded = true
            try validate()
            try checkpointFile(files).save(checkpoint, replacing: previous)
        }
        try await validateCurrentAuthority(validate)
        StorageTransferProcessState.markCloudMirrorOpened()
        let container = try StorageTransferPersistence.makeContainer(selection: journal.destination,
            urls: files.storeURLs(for: journal.destination, location: .staged), cloudEnabled: true)
        track(container, true)
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while true {
            try validate()
            let nowControl = try await remoteRecoveryStatus(binding: journal.cloudBinding, validateAccess: validate)
            guard nowControl == expectedControl else { throw StorageTransferRuntimeError.remoteRecoveryRequired }
            let observed = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: journal.cloudBinding, validateTransfer: validate)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let replica = try PomoGemStorageSnapshot.observeCloudReplica(from: context)
            let matches = try replica.isEquivalent(to: observed.snapshot, entities: PomoGemStorageSnapshot.cloudModelNames,
                normalizeEmptyRelationships: true, dateTolerance: 0.001)
            if matches, try !journal.choice.replacesCloud || replica.isEquivalent(to: source, normalizeEmptyRelationships: true) {
                guard try FocusCloudSyncStore.canonicalActive(context: context) == nil else { throw StorageTransferError.activeTimer }
                try await requireCloudEquals(replica, binding: journal.cloudBinding, validate: validate)
                let proof = journal.choice.replacesCloud ? digest : try saveDestinationPayload(replica, files: files)
                let previous = checkpoint
                checkpoint.verifiedCloudPayloadDigest = proof
                checkpoint.verifiedCloudProcessID = Self.processID
                try validate()
                try checkpointFile(files).save(checkpoint, replacing: previous)
                throw StorageTransferRuntimeError.relaunchRequired
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw StorageTransferRuntimeError.cloudCopyStillPending }
            try await Task.sleep(for: .seconds(2))
        }
    }

    private func importLocal(_ snapshot: PomoGemStorageSnapshot, digest: String, journal: StorageTransferJournal,
                             files: StorageTransferStoreFiles, checkpoint: inout StorageTransferRuntimeCheckpoint,
                             track: @MainActor (ModelContainer, Bool) -> Void) throws {
        if let saved = checkpoint.importedPayloadDigest {
            guard saved == digest else { throw StorageTransferError.snapshotMismatch }
            return
        }
        try StorageTransferPersistence.requireAllReleased()
        try files.discardUnacknowledgedStaged(destination: journal.destination)
        try autoreleasepool {
            let container = try StorageTransferPersistence.makeContainer(selection: journal.destination,
                urls: files.storeURLs(for: journal.destination, location: .staged), cloudEnabled: false)
            track(container, false)
            let context = ModelContext(container)
            context.autosaveEnabled = false
            _ = try snapshot.importIntoEmpty(context)
            guard try FocusCloudSyncStore.canonicalActive(context: context) == nil else { throw StorageTransferError.activeTimer }
            let readback = try PomoGemStorageSnapshot.capture(from: ModelContext(container))
            guard try snapshot.isEquivalent(to: readback, normalizeEmptyRelationships: true) else { throw StorageTransferError.snapshotMismatch }
        }
        let previous = checkpoint
        checkpoint.importedPayloadDigest = digest
        try checkpointFile(files).save(checkpoint, replacing: previous)
    }

    private func verifyDestination(_ journal: StorageTransferJournal,
                                   validate: @escaping @MainActor () throws -> Void) async throws -> String {
        let files = try files(journal)
        let actual = try readStaged(journal, files: files)
        let expected: PomoGemStorageSnapshot
        let digest: String
        if journal.choice == .enableCloudKeepingCloud {
            expected = try destinationPayloadFile(files).load().unwrapTransfer()
            digest = try snapshotDigest(expected)
        } else {
            digest = try journal.sourceDigest.unwrapTransfer()
            expected = try StorageTransferPayloadStore(files: files).load(expectedDigest: digest)
        }
        guard try actual.isEquivalent(to: expected, normalizeEmptyRelationships: true) else { throw StorageTransferError.snapshotMismatch }
        if journal.choice != .disableCloudKeepingCopy {
            try await requireCloudEquals(actual, binding: journal.cloudBinding, validate: validate)
        }
        return digest
    }

    private func promote(_ journal: StorageTransferJournal,
                         validate: @escaping @MainActor () throws -> Void) async throws {
        try releasePolicy.validate(journal.choice)
        guard !StorageTransferProcessState.cloudMirrorWasOpened else { throw StorageTransferRuntimeError.relaunchRequired }
        let files = try files(journal)
        try StorageTransferPersistence.requireAllReleased()
        let manifest = try files.loadStagedManifest(destination: journal.destination)
            ?? files.sealStaged(destination: journal.destination)
        try validate()
        if journal.choice.replacesCloud {
            guard let recoveryManifest = try checkpoint(files, journal: journal).recoveryManifest,
                  let digest = journal.destinationDigest else { throw StorageTransferError.invalidJournal }
            _ = try await remote(validate).commitReplacement(manifest: recoveryManifest, verifiedDestinationSHA256: digest)
        }
        if case .cloud(let binding) = journal.destination {
            let status = try await remoteRecoveryStatus(binding: binding, validateAccess: validate)
            guard status?.blocksWriters != true else { throw StorageTransferRuntimeError.remoteRecoveryRequired }
            let admission = try admissionFile(binding)
            let previous = try admission.load()
            try admission.save(StorageTransferDatasetAdmission(binding: binding,
                datasetGenerationID: status?.datasetGenerationID), replacing: previous)
            recordReplacementWatch(journal: journal, files: files, binding: binding,
                                   generationID: status?.datasetGenerationID)
        }
        try validate()
        try files.promoteStaged(destination: journal.destination, manifest: manifest)
    }

    /// PLAN Step 9. Leave a receipt so the next settled mount can look ONCE for
    /// rows a device the purge could not fence pushed in afterwards. A
    /// detector, never a fence, and never destructive. Failing to write it must
    /// not fail an otherwise complete commit, so every error is swallowed here
    /// on purpose: losing a diagnostic is strictly better than losing a
    /// promotion that already deleted and re-exported the dataset.
    private func recordReplacementWatch(journal: StorageTransferJournal,
                                        files: StorageTransferStoreFiles,
                                        binding: ActiveAccountLocalBinding,
                                        generationID: UUID?) {
        guard journal.choice.replacesCloud, let generationID else { return }
        do {
            // Already computed by captureSource; no new traversal of the store.
            guard let receipt = try StorageTransferPayloadStore(files: files).acknowledgedReceipt() else { return }
            try StorageTransferReplacementWatchStore(root: root, namespace: binding.namespace)
                .record(datasetGenerationID: generationID,
                        committedCounts: receipt.recordCounts, committedAt: Date())
        } catch { }
    }

    /// PLAN Step 9, the one read-only comparison. The host calls this at the
    /// first settled cloud mount after a commit; a `.lateArrival` outcome is
    /// non-blocking banner state only. The receipt is removed whatever the
    /// result, so this can never run twice for one commit.
    func evaluateReplacementWatch(binding: ActiveAccountLocalBinding,
                                  currentGenerationID: UUID?,
                                  locallyAuthoredSinceCommit: [String: Int] = [:],
                                  timeout: TimeInterval = StorageTransferCloudPreviewPolicy.timeout,
                                  validateAccess: @escaping @MainActor () throws -> Void) async -> StorageTransferReplacementWatchOutcome {
        guard let store = try? StorageTransferReplacementWatchStore(root: root, namespace: binding.namespace) else {
            return .noReceipt
        }
        return await store.evaluate(currentGenerationID: currentGenerationID,
                                    locallyAuthoredSinceCommit: locallyAuthoredSinceCommit) {
            try await CloudStorageTransferCloudKit(timeout: timeout)
                .readSnapshot(expectedBinding: binding, validateTransfer: validateAccess).snapshot.recordCounts
        }
    }

    private func requireStableCloudCopy(context: ModelContext, binding: ActiveAccountLocalBinding,
                                        validate: @escaping @MainActor () throws -> Void) async throws {
        let snapshot = try PomoGemStorageSnapshot.observeCloudReplica(from: ModelContext(context.container))
        try await requireCloudEquals(snapshot, binding: binding, validate: validate)
    }

    private func requireCloudEquals(_ snapshot: PomoGemStorageSnapshot, binding: ActiveAccountLocalBinding,
                                     validate: @escaping @MainActor () throws -> Void) async throws {
        try await validateCurrentAuthority(validate)
        let first = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: binding, validateTransfer: validate)
        try await validateCurrentAuthority(validate)
        guard try snapshot.isEquivalent(to: first.snapshot, entities: PomoGemStorageSnapshot.cloudModelNames,
            normalizeEmptyRelationships: true, dateTolerance: 0.001) else { throw StorageTransferRuntimeError.cloudCopyStillPending }
        let second = try await CloudStorageTransferCloudKit().readSnapshot(expectedBinding: binding, validateTransfer: validate)
        try await validateCurrentAuthority(validate)
        guard try first.snapshot.isEquivalent(to: second.snapshot, normalizeEmptyRelationships: true),
              try snapshot.isEquivalent(to: second.snapshot, entities: PomoGemStorageSnapshot.cloudModelNames,
                  normalizeEmptyRelationships: true, dateTolerance: 0.001) else { throw StorageTransferRuntimeError.cloudCopyStillPending }
    }

    private func readStaged(_ journal: StorageTransferJournal, files: StorageTransferStoreFiles) throws -> PomoGemStorageSnapshot {
        try StorageTransferPersistence.requireAllReleased()
        let urls = try files.makeStagedReaderCopy(destination: journal.destination)
        return try autoreleasepool {
            let container = try StorageTransferPersistence.makeContainer(selection: journal.destination, urls: urls, cloudEnabled: false)
            let context = ModelContext(container)
            guard try FocusCloudSyncStore.canonicalActive(context: context) == nil else { throw StorageTransferError.activeTimer }
            return try PomoGemStorageSnapshot.capture(from: context)
        }
    }

    private func withAuthority<Value>(_ journal: StorageTransferJournal,
                                      validate: @escaping @MainActor () throws -> Void,
                                      operation: @MainActor () async throws -> Value) async throws -> Value {
        try await validateCurrentAuthority(validate)
        guard try store.load() == journal else { throw StorageTransferError.staleTransaction }
        let result = try await operation()
        try await validateCurrentAuthority(validate)
        guard try store.load() == journal else { throw StorageTransferError.staleTransaction }
        return result
    }

    private func validateCurrentAuthority(_ validate: @escaping @MainActor () throws -> Void) async throws {
        try validate()
        // begin() has not published a journal yet. Its explicit initial
        // control observation is captured by the acceptance path instead.
        guard let journal = try store.load(), journal.phase < .selectionCommitted else { return }
        let checkpoint = try checkpoint(files(journal), journal: journal)
        let observed = try await remote(validate).inspect(accountFingerprint: journal.cloudBinding.accountFingerprint)?.control
        try validate()
        guard try store.load() == journal else { throw StorageTransferError.staleTransaction }
        try StorageTransferCloudAuthorityFence.validate(observed: observed, journal: journal, checkpoint: checkpoint)
    }

    private func cleanup() throws -> StorageTransferCleanup {
        try StorageTransferCleanup(featureRoot: root, journalStore: store, validateLocalCleanup: {
            try StorageTransferPersistence.requireAllReleased()
            guard !StorageTransferProcessState.cloudMirrorWasOpened else { throw StorageTransferRuntimeError.relaunchRequired }
        })
    }

    private func remoteCancellation() throws -> StorageTransferRemoteCancellation {
        // Journal reads create and validate the common state directory on a
        // genuine clean install before any strict worker opens it.
        _ = try store.load()
        return try StorageTransferRemoteCancellation(featureRoot: root, journalStore: store, cleanup: cleanup())
    }

    private func requireNoPendingRemoteCancellation() throws {
        guard try pendingRemoteCancellationIntent() == nil else {
            throw StorageTransferRemoteCancellationError.conflictingIntent
        }
    }

    private func remote(_ validate: @escaping @MainActor () throws -> Void) -> StorageTransferRemoteRecovery {
        StorageTransferRemoteRecovery(backend: StorageTransferRemoteRecoveryCloudKit(validateAccess: validate), validateAccess: validate)
    }
    private func files(_ journal: StorageTransferJournal) throws -> StorageTransferStoreFiles {
        try StorageTransferStoreFiles(transactionID: journal.transactionID, transferRoot: root,
                                      storeDirectory: storeDirectory)
    }
    private func checkpointFile(_ files: StorageTransferStoreFiles) throws -> StorageTransferStateFile<StorageTransferRuntimeCheckpoint> {
        try StorageTransferStateFile(url: files.transactionDirectory.appendingPathComponent("runtime-v1.json"))
    }
    private func checkpoint(_ files: StorageTransferStoreFiles, journal: StorageTransferJournal) throws -> StorageTransferRuntimeCheckpoint {
        guard let value = try checkpointFile(files).load() else { throw StorageTransferError.invalidJournal }
        try value.validate(journal: journal)
        return value
    }
    private func destinationPayloadFile(_ files: StorageTransferStoreFiles) throws -> StorageTransferStateFile<PomoGemStorageSnapshot> {
        try StorageTransferStateFile(url: files.transactionDirectory.appendingPathComponent("destination-payload-v1.json"),
            maximumBytes: PomoGemStorageSnapshot.Limits.standard.maximumEncodedBytes)
    }
    private func saveDestinationPayload(_ value: PomoGemStorageSnapshot, files: StorageTransferStoreFiles) throws -> String {
        try value.validate()
        let file = try destinationPayloadFile(files)
        if let existing = try file.load() {
            guard try existing.isEquivalent(to: value, normalizeEmptyRelationships: true) else { throw StorageTransferError.snapshotMismatch }
            return try snapshotDigest(existing)
        }
        try file.save(value, replacing: nil)
        return try snapshotDigest(value)
    }
    private func snapshotDigest(_ value: PomoGemStorageSnapshot) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try StorageTransferRecoverySchema.digest(encoder.encode(value))
    }
    private func admissionFile(_ binding: ActiveAccountLocalBinding) throws -> StorageTransferStateFile<StorageTransferDatasetAdmission> {
        try StorageTransferStateFile(url: root.appendingPathComponent("admission-\(binding.namespace.rawValue).json"))
    }
    private func requireNoArtifacts(selection: PersistenceDeploymentSelection) throws {
        let urls = try PersistenceStoreTopology.persistentStoreURLs(for: selection.storageLaunchMode,
            accountNamespace: selection.storageNamespace)
        for url in urls.flatMap({ PersistenceStoreArtifactLayout.artifacts(for: $0) }) {
            var info = stat()
            guard lstat(url.path, &info) != 0, errno == ENOENT else { throw StorageTransferRuntimeError.datasetRefreshRequired }
        }
    }
}

private extension Optional {
    func unwrapTransfer() throws -> Wrapped {
        guard let self else { throw StorageTransferError.invalidJournal }
        return self
    }
}
