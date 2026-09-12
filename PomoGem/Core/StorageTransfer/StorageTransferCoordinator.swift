import Foundation

/// Each effect is idempotent for this journal's immutable transaction ID.
/// Implementations must use the frozen payload, never recapture a newly edited
/// source when resuming an acknowledged checkpoint. Destination preparation
/// owns a separate remote CAS journal when it can replace cloud contents.
struct StorageTransferEffects {
    var captureSource: @MainActor @Sendable (StorageTransferJournal) async throws -> String
    var saveRemoteRecovery: @MainActor @Sendable (StorageTransferJournal) async throws -> StorageTransferRecoveryManifest
    var prepareDestination: @MainActor @Sendable (StorageTransferJournal) async throws -> String
    var verifyDestination: @MainActor @Sendable (StorageTransferJournal) async throws -> String
    var promoteDestination: @MainActor @Sendable (StorageTransferJournal) async throws -> Void
    var retireSource: @MainActor @Sendable (StorageTransferJournal) async throws -> Void
    var enqueueCleanup: @MainActor @Sendable (StorageTransferJournal) async throws -> Void
}

/// Drives the local half of the transfer. Pending state remains on every
/// failure, including cancellation and ambiguous remote replies. The launch
/// host must run this before mounting a writable application session.
@MainActor
final class StorageTransferCoordinator {
    private let store: StorageTransferJournalStore
    private let effects: StorageTransferEffects
    private var isRunning = false

    init(store: StorageTransferJournalStore, effects: StorageTransferEffects) {
        self.store = store
        self.effects = effects
    }

    func resume(transactionID: UUID,
                validateTransfer: () throws -> Void,
                progress: (StorageTransferJournal.Phase) -> Void = { _ in }) async throws {
        guard !isRunning else { throw StorageTransferError.staleTransaction }
        isRunning = true
        defer { isRunning = false }

        func validate(_ journal: StorageTransferJournal) throws {
            try Task.checkCancellation()
            try validateTransfer()
            guard journal.transactionID == transactionID, try store.load() == journal else {
                throw StorageTransferError.staleTransaction
            }
        }
        guard var journal = try store.load(), journal.transactionID == transactionID else {
            throw StorageTransferError.staleTransaction
        }
        while true {
            try validate(journal)
            progress(journal.phase)
            let next: StorageTransferJournal
            switch journal.phase {
            case .requested:
                let digest = try await effects.captureSource(journal)
                try validate(journal)
                next = try journal.advancing(to: .sourceSaved, sourceDigest: digest)
            case .sourceSaved:
                var receipt: UUID?
                if journal.choice.replacesCloud {
                    let manifest = try await effects.saveRemoteRecovery(journal)
                    try validate(journal)
                    try manifest.validate()
                    guard manifest.transactionID == journal.transactionID,
                          manifest.accountFingerprint == journal.cloudBinding.accountFingerprint,
                          manifest.payloadSHA256 == journal.sourceDigest else {
                        throw StorageTransferError.recoveryCopyRequired
                    }
                    receipt = manifest.transactionID
                }
                next = try journal.advancing(to: .recoveryCopySaved,
                                             remoteRecoveryTransactionID: receipt)
            case .recoveryCopySaved:
                // This intent must be durable before an effect can perform any
                // irreversible remote change. Later cancellation means resume.
                next = try journal.advancing(to: .preparingDestination)
            case .preparingDestination:
                let digest = try await effects.prepareDestination(journal)
                try validate(journal)
                next = try journal.advancing(to: .destinationSaved, destinationDigest: digest)
            case .destinationSaved:
                let verifiedDigest = try await effects.verifyDestination(journal)
                try validate(journal)
                guard verifiedDigest == journal.destinationDigest else {
                    throw StorageTransferError.snapshotMismatch
                }
                next = try journal.advancing(to: .destinationVerified)
            case .destinationVerified:
                try await effects.promoteDestination(journal)
                try validate(journal)
                try store.commitSelection(for: journal)
                next = try journal.advancing(to: .selectionCommitted)
            case .selectionCommitted:
                try await effects.retireSource(journal)
                try validate(journal)
                next = try journal.advancing(to: .sourceRetired)
            case .sourceRetired:
                try await effects.enqueueCleanup(journal)
                try validate(journal)
                try store.finish(journal)
                return
            }
            try store.save(next, replacing: journal)
            journal = next
        }
    }
}
