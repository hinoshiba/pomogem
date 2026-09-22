import Foundation

/// Read-only authority for an explicitly recorded namespace replacement. The
/// legacy account registry is never rewritten, and callers cannot provide an
/// arbitrary replacement binding: authority is reread from the durable journal
/// and the atomic verified-selection receipt around the online identity proof.
@MainActor
struct StorageTransferAccountNamespaceAuthority: Equatable {
    private let pending: StorageTransferJournal?
    private let committed: StorageTransferCommittedSelection?

    private init(pending: StorageTransferJournal?, committed: StorageTransferCommittedSelection?) {
        self.pending = pending
        self.committed = committed
    }

    static func read(from store: StorageTransferJournalStore?) throws -> Self {
        guard let store else { return Self(pending: nil, committed: nil) }
        let pending = try store.load()
        let committed = try store.committedSelection()
        if let pending, let committed {
            let commitsPendingDestination: Bool
            if pending.phase >= .destinationVerified {
                commitsPendingDestination = committed == (try StorageTransferCommittedSelection(journal: pending))
            } else { commitsPendingDestination = false }
            guard commitsPendingDestination || committed.selection == pending.source else {
                throw StorageTransferError.invalidJournal
            }
        }
        return Self(pending: pending, committed: committed)
    }

    /// Nil delegates to the unmodified ordinary namespace-registry policy.
    /// A committed cloud selection supersedes that policy even without an
    /// expected binding, so a later normal launch cannot select the old cache.
    func decision(verifiedFingerprint: String, expectedBinding: ActiveAccountLocalBinding?,
                  registry: AppleAccountNamespaceRegistry) -> AppleAccountBoundaryDecision? {
        guard AppleAccountFingerprint.isValid(verifiedFingerprint) else {
            return .block(.invalidVerifiedIdentity)
        }
        if let expectedBinding, expectedBinding.accountFingerprint != verifiedFingerprint {
            return .block(.accountMismatch)
        }

        let committedBinding: ActiveAccountLocalBinding?
        if case let .cloud(binding)? = committed?.selection { committedBinding = binding }
        else { committedBinding = nil }
        if let committedBinding, committedBinding.accountFingerprint != verifiedFingerprint {
            return .block(.accountMismatch)
        }

        // `replacesCloud` covers both replacement kinds. The only overwrite
        // shape with a local-only source is the reinstall resume, which needs
        // exactly the authority the legacy replacement already had here.
        if let pending,
           pending.choice == .enableCloudKeepingCloud || pending.choice.replacesCloud,
           case .localOnly = pending.source,
           case let .cloud(destination) = pending.destination,
           let committed, committed.selection == pending.source {
            guard destination.accountFingerprint == verifiedFingerprint else { return .block(.accountMismatch) }
            // A user may change Apple Account while local-only. The exact
            // request from the committed local source authorizes its recorded
            // destination even when the legacy registry still contains A.
            return resolveAuthorized(destination, expected: expectedBinding, registry: registry)
        }

        if let pending, pending.choice == .disableCloudKeepingCopy,
           case let .cloud(source) = pending.source,
           case .localOnly = pending.destination,
           pending.phase >= .destinationVerified,
           let committed,
           committed == (try? StorageTransferCommittedSelection(journal: pending)) {
            guard source.accountFingerprint == verifiedFingerprint else { return .block(.accountMismatch) }
            // The local receipt has replaced the previous cloud receipt, but
            // restart must still authenticate that exact cloud source until
            // its recorded retirement completes. This grants no cloud mount.
            return resolveAuthorized(source, expected: expectedBinding, registry: registry)
        }

        // A cloud -> cloud overwrite mints a new destination namespace from the
        // old cache exactly as a refresh does, so its `committedBinding ==
        // destination` handoff and ordinary-registry fallback apply unchanged.
        // The legacy `enableCloudReplacingCloud` has no cloud-source shape and
        // is deliberately not admitted here.
        if let pending,
           pending.choice == .enableCloudKeepingCloud || pending.choice == .overwriteCloudFromDevice,
           case let .cloud(source) = pending.source,
           case let .cloud(destination) = pending.destination {
            guard source.accountFingerprint == verifiedFingerprint,
                  destination.accountFingerprint == verifiedFingerprint else {
                return .block(.accountMismatch)
            }
            // A receipt written immediately before the journal's committed
            // phase already makes the old source ineligible for resolution.
            if committedBinding == destination {
                return resolveAuthorized(destination, expected: expectedBinding, registry: registry)
            }
            if let committedBinding {
                guard committedBinding == source else { return .block(.invalidStoredRegistry) }
            } else {
                var ordinary = registry
                guard ordinary.resolve(.verified(fingerprint: verifiedFingerprint), expectedBinding: source) == .allow(source) else {
                    return .block(.invalidStoredRegistry)
                }
            }
            if expectedBinding == destination {
                return resolveAuthorized(destination, expected: expectedBinding, registry: registry)
            }
            if let expectedBinding, expectedBinding != source {
                return .block(.invalidStoredRegistry)
            }
            // Source authentication remains possible until commit, but merely
            // reading this pending request never authorizes a normal source
            // mount; the host's pending-journal gate must remain in place.
            return resolveAuthorized(source, expected: expectedBinding, registry: registry)
        }

        if let committedBinding {
            return resolveAuthorized(committedBinding, expected: expectedBinding, registry: registry)
        }
        return nil
    }

    private func resolveAuthorized(_ binding: ActiveAccountLocalBinding,
                                   expected: ActiveAccountLocalBinding?,
                                   registry: AppleAccountNamespaceRegistry) -> AppleAccountBoundaryDecision {
        guard expected == nil || expected == binding,
              !registry.entries.contains(where: {
                  $0.key != binding.accountFingerprint && $0.value.namespace == binding.namespace
              }) else { return .block(.invalidStoredRegistry) }
        return .allow(binding)
    }
}
