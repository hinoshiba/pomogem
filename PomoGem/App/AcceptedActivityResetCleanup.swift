import Foundation

/// Local-only retry evidence. Capture the namespace key at acceptance so a
/// completion arriving after account retirement cannot clear another account's
/// receipt. A new receipt also protects a later reset of the same epoch.
@MainActor
struct ActivityResetCleanupJournal {
    static let defaultsBaseKey = "activity.pending-external-reset-cleanup.v1"

    struct Receipt: Equatable {
        let epochID: UUID
        let identifier: UUID
    }

    struct Ticket {
        let receipt: Receipt
        fileprivate let journal: ActivityResetCleanupJournal

        @MainActor fileprivate func complete() { journal.complete(receipt) }
    }

    let defaults: UserDefaults
    let key: String

    static func live(defaults: UserDefaults = .standard) -> Self {
        Self(
            defaults: defaults,
            key: AccountScopedLocalState.defaultsKey(
                base: defaultsBaseKey, defaults: defaults
            )
        )
    }

    var hasPendingCleanup: Bool { defaults.object(forKey: key) != nil }

    var pendingReceipt: Receipt? {
        guard let values = defaults.dictionary(forKey: key),
              let epoch = values["epoch"] as? String,
              let epochID = UUID(uuidString: epoch),
              let identifier = values["receipt"] as? String,
              let receiptID = UUID(uuidString: identifier) else { return nil }
        return Receipt(epochID: epochID, identifier: receiptID)
    }

    /// Record this before acknowledging the epoch in the local application
    /// marker. A process restart then sees either an unapplied epoch or its
    /// pending cleanup receipt, including when no async observer ever ran.
    func begin(epochID: UUID) -> Ticket {
        let receipt = Receipt(epochID: epochID, identifier: UUID())
        defaults.set([
            "epoch": epochID.uuidString.lowercased(),
            "receipt": receipt.identifier.uuidString.lowercased()
        ], forKey: key)
        return Ticket(receipt: receipt, journal: self)
    }

    private func complete(_ receipt: Receipt) {
        guard pendingReceipt == receipt else { return }
        defaults.removeObject(forKey: key)
    }
}

/// A persisted reset must finish its accepted external effects even if the
/// first-frame/deferred-maintenance view task never runs. Retaining the old
/// store's owner also prevents a replacement cloud session from appearing
/// while this cleanup can still end an activity or clear notifications.
@MainActor
enum AcceptedActivityResetCleanup {
    static func start(
        after previous: Task<Void, Error>? = nil,
        retaining lifetimeOwner: AnyObject,
        completing ticket: ActivityResetCleanupJournal.Ticket? = nil,
        operation: @escaping @MainActor () async throws -> Void
    ) -> Task<Void, Error> {
        Task { @MainActor in
            defer { withExtendedLifetime(lifetimeOwner) {} }
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            try await operation()
            try Task.checkCancellation()
            ticket?.complete()
        }
    }
}
