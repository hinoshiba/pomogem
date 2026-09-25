import Foundation
import OSLog
import SwiftData

/// sync-03 (PR 19). On iOS 18 and later, tells this process's own writes apart
/// from real imports before an `NSPersistentStoreRemoteChange` revokes
/// presentation trust.
///
/// Core Data posts that notification for every write to the CloudKit source
/// store, this process's own included (verified with a same-process
/// experiment during the audit). Until now every pause/resume, settings toggle
/// and timer-claim write therefore revoked iCloud presentation trust, reset
/// the aggregates cursor and started a full verification sweep, so the jar's
/// lifetime mass was replaced by 「再集計中」 for minutes at a time.
///
/// This implements the part of Docs/SyncMaintenanceArchitecture.md §10.1 the
/// trigger needs: SwiftData History since a process-local cursor decides
/// whether any transaction by an author other than this app's UI or
/// maintenance contexts changed a CloudKit source model. Only then does the
/// notification escalate as before. It fails closed everywhere else:
/// - iOS 17 has no SwiftData History and keeps today's behaviour;
/// - any history error, an expired token or a cursor that cannot be read
///   escalates;
/// - an unauthored transaction (for example a secondary context, or the
///   CloudKit mirroring import) counts as foreign;
/// - an empty answer before the cursor has a token escalates, because the
///   time-based first window cannot prove the change was already seen;
/// - more transactions than one read classifies escalates.
/// The app's own session saves keep invalidating through the main context's
/// `didSave` rule, which is unchanged.
///
/// The shipping container has two stores, the CloudKit source store and the
/// local projection store (AggregatePebble, Stratum, Bedrock, GachaState),
/// and a SwiftData History token is per store. The cursor therefore follows
/// the source store only: it advances only from source-store transactions,
/// and projection-store transactions — which cannot change a CloudKit source
/// model — never decide a verdict. A cursor that advanced to a projection
/// token used to hide every later source transaction, so each remote change,
/// real imports included, read as "already classified" for the rest of that
/// Root's life. Any doubt about which store is the source store escalates.
struct SyncHistoryTransactionSummary: Equatable, Sendable {
    let author: String?
    let changedEntityNames: Set<String>
    /// SwiftData's identifier of the store that recorded the transaction.
    var storeIdentifier: String = ""
}

enum SyncRemoteChangeHistoryPolicy {
    enum Verdict: Equatable, Sendable {
        /// Every transaction since the cursor was written by this app's own
        /// UI or maintenance context, or touched no CloudKit source model.
        case ignoreOwnWrites
        case invalidate
    }

    static let ownAuthors: Set<String> = [
        SyncMaintenanceNotificationPolicy.uiAuthor,
        SyncMaintenanceNotificationPolicy.maintenanceAuthor
    ]

    /// The models mirrored to CloudKit. A foreign change to any of them keeps
    /// escalating exactly as every remote change did before.
    static let sourceEntityNames = PomoGemStorageSnapshot.cloudModelNames

    static let maximumTransactionsPerRead = 500

    static func verdict(
        transactions: [SyncHistoryTransactionSummary],
        cursorHadToken: Bool,
        readWasTruncated: Bool = false
    ) -> Verdict {
        guard !readWasTruncated else { return .invalidate }
        guard !transactions.isEmpty else {
            // With a token, an empty answer means an earlier read already
            // classified this change. Before the first token the window is
            // only a time, which cannot prove that.
            return cursorHadToken ? .ignoreOwnWrites : .invalidate
        }
        let foreign = transactions.contains { transaction in
            let isOwn = transaction.author.map { ownAuthors.contains($0) } ?? false
            return !isOwn && !transaction.changedEntityNames.isDisjoint(with: sourceEntityNames)
        }
        return foreign ? .invalidate : .ignoreOwnWrites
    }
}

extension SyncRemoteChangeHistoryPolicy {
    enum StoreResolution: Equatable, Sendable {
        /// The source store's identifier, and only its transactions.
        case source(identifier: String?, transactions: [SyncHistoryTransactionSummary])
        /// More than one store changed a source model, or a source model
        /// changed in a store other than the one the cursor follows.
        case ambiguous
    }

    /// Which of `transactions` belong to the CloudKit source store. The source
    /// store is the one whose transactions change source models; once known,
    /// the cursor keeps following it.
    static func sourceTransactions(
        _ transactions: [SyncHistoryTransactionSummary],
        knownSourceStore: String?
    ) -> StoreResolution {
        let sourceStores = Set(transactions
            .filter { !$0.changedEntityNames.isDisjoint(with: sourceEntityNames) }
            .map(\.storeIdentifier))
        guard sourceStores.count <= 1 else { return .ambiguous }
        if let knownSourceStore, let seen = sourceStores.first, seen != knownSourceStore {
            return .ambiguous
        }
        guard let store = knownSourceStore ?? sourceStores.first else {
            return .source(identifier: nil, transactions: [])
        }
        return .source(identifier: store, transactions: transactions.filter { $0.storeIdentifier == store })
    }
}

/// Process-local. The launch verification sweep covers everything before the
/// first frame, so the cursor starts there and only needs to classify what
/// happens while Root is mounted.
struct SyncRemoteChangeHistoryCursor: Equatable, Sendable {
    /// The last classified source-store `DefaultHistoryToken`, JSON-encoded
    /// so this type stays available on iOS 17. Never a projection token.
    fileprivate(set) var tokenData: Data?
    /// The store `tokenData` belongs to: the CloudKit source store.
    fileprivate(set) var sourceStoreIdentifier: String?
    fileprivate(set) var since: Date

    init(since: Date) {
        self.since = since
    }
}

@available(iOS 18, *)
@MainActor
enum SyncRemoteChangeHistoryReader {
    private static let logger = Logger(subsystem: "com.hinoshiba.pomogem", category: "SyncMaintenance")

    /// Reads and classifies every transaction since `cursor`, advancing it.
    /// Any failure resets the cursor's token and returns `.invalidate`.
    static func classify(
        context: ModelContext,
        cursor: inout SyncRemoteChangeHistoryCursor,
        now: Date = .now
    ) -> SyncRemoteChangeHistoryPolicy.Verdict {
        let hadToken = cursor.tokenData != nil
        do {
            var descriptor = HistoryDescriptor<DefaultHistoryTransaction>()
            if let data = cursor.tokenData {
                let token = try JSONDecoder().decode(DefaultHistoryToken.self, from: data)
                descriptor.predicate = #Predicate { $0.token > token }
            } else {
                let since = cursor.since
                descriptor.predicate = #Predicate { $0.timestamp > since }
            }
            descriptor.fetchLimit = UInt64(SyncRemoteChangeHistoryPolicy.maximumTransactionsPerRead)
            let transactions = try context.fetchHistory(descriptor)
            let summaries = transactions.map { transaction in
                SyncHistoryTransactionSummary(
                    author: transaction.author,
                    changedEntityNames: Set(transaction.changes.map(\.changedPersistentIdentifier.entityName)),
                    storeIdentifier: transaction.storeIdentifier
                )
            }
            let truncated = transactions.count >= SyncRemoteChangeHistoryPolicy.maximumTransactionsPerRead
            guard case let .source(store, sourceSummaries) = SyncRemoteChangeHistoryPolicy.sourceTransactions(
                summaries, knownSourceStore: cursor.sourceStoreIdentifier
            ) else {
                return startNewWindow(&cursor, now: now)
            }
            // Only a source-store token may become the cursor: tokens of
            // different stores do not order against each other.
            if let store,
               let latest = transactions.filter({ $0.storeIdentifier == store }).map(\.token).max() {
                cursor.tokenData = try JSONEncoder().encode(latest)
                cursor.sourceStoreIdentifier = store
            }
            return SyncRemoteChangeHistoryPolicy.verdict(
                transactions: sourceSummaries,
                cursorHadToken: hadToken,
                readWasTruncated: truncated
            )
        } catch {
            return startNewWindow(&cursor, now: now)
        }
    }

    /// An expired or unreadable token, or a doubt about the stores, starts a
    /// new time window; the escalation it causes re-verifies everything
    /// before it.
    private static func startNewWindow(
        _ cursor: inout SyncRemoteChangeHistoryCursor,
        now: Date
    ) -> SyncRemoteChangeHistoryPolicy.Verdict {
        cursor.tokenData = nil
        cursor.sourceStoreIdentifier = nil
        cursor.since = now
        logger.notice("Remote-change history could not be classified; treating it as an import")
        return .invalidate
    }
}

#if DEBUG
extension SyncRemoteChangeHistoryCursor {
    /// Tests only: a token the reader cannot decode.
    mutating func corruptTokenForTesting() {
        tokenData = Data("not a history token".utf8)
    }
}
#endif
