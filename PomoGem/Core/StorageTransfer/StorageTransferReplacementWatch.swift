import Darwin
import Foundation

/// The receipt a committed cloud replacement leaves behind so the NEXT settled
/// mount can look once for rows that arrived from a device the purge could not
/// fence (`Docs/MultiDeviceCloudSafety.md` defect 1: an already-running or
/// older-build installation can keep pushing pre-purge rows into the recreated
/// zone).
///
/// This is a DETECTOR, not a fence. It is bounded to one comparison, it cannot
/// prevent contamination, and a device that flushes days later is never caught.
/// Its only effect is a non-blocking banner; it deletes nothing but itself.
struct StorageTransferReplacementWatch: Codable, Equatable, Sendable {
    var formatVersion = 1
    /// The generation this device committed. A receipt whose generation is no
    /// longer the current one says nothing and is dropped unread.
    let datasetGenerationID: UUID
    /// Mirrored-model counts of the payload this device committed, taken from
    /// the payload receipt that `captureSource` already computed — no new
    /// traversal of the store.
    let committedCounts: [String: Int]
    let committedAt: Date
    /// Bounded: a read that fails survives exactly `maximumReadFailures` more
    /// launches and is then dropped, so a permanently offline account never
    /// accumulates work.
    var readFailures = 0
}

enum StorageTransferReplacementWatchOutcome: Equatable {
    /// Nothing to do: no commit of ours is awaiting its one comparison.
    case noReceipt
    /// The account moved to a different generation; our receipt can no longer
    /// say anything about it.
    case superseded
    /// Looked once, saw nothing the committed payload did not already hold.
    case cleared
    /// The server holds rows the committed payload did not, in these mirrored
    /// models (sorted). Non-blocking banner state only — never destructive,
    /// never a reason to re-run anything automatically.
    case lateArrival(models: [String])
    /// The one read failed; the receipt is kept for one more launch.
    case deferred
    /// The read failed again; the receipt is dropped rather than retried forever.
    case dropped
}

@MainActor
struct StorageTransferReplacementWatchStore {
    /// One retry, then give up. The detector must never become a launch cost.
    static let maximumReadFailures = 1

    private let file: StorageTransferStateFile<StorageTransferReplacementWatch>

    init(root: URL, namespace: AccountDataNamespace) throws {
        file = try StorageTransferStateFile(
            url: root.appendingPathComponent("replacement-watch-\(namespace.rawValue).json"))
    }

    func load() throws -> StorageTransferReplacementWatch? { try file.load() }

    /// Written at `promote`, right after the dataset admission file. Only
    /// mirrored models are kept: a local-only model can never appear in a
    /// server count comparison, so storing it would only invite a false
    /// positive later.
    func record(datasetGenerationID: UUID, committedCounts: [String: Int], committedAt: Date) throws {
        let mirrored = committedCounts.filter { PomoGemStorageSnapshot.cloudModelNames.contains($0.key) }
        guard mirrored.values.allSatisfy({ $0 >= 0 }) else { throw StorageTransferError.invalidJournal }
        let value = StorageTransferReplacementWatch(datasetGenerationID: datasetGenerationID,
                                                    committedCounts: mirrored, committedAt: committedAt)
        let previous = try file.load()
        guard previous != value else { return }
        try file.save(value, replacing: previous)
    }

    /// The single post-commit comparison. `read` returns the server's per-model
    /// counts from ONE read-only snapshot; this function opens no container and
    /// writes nothing but its own receipt, which it removes whatever the
    /// result. `locallyAuthoredSinceCommit` lets a caller that knows how many
    /// rows THIS device added after the commit keep ordinary local growth from
    /// being reported as somebody else's late arrival.
    func evaluate(currentGenerationID: UUID?,
                  locallyAuthoredSinceCommit: [String: Int] = [:],
                  read: () async throws -> [String: Int]) async -> StorageTransferReplacementWatchOutcome {
        let existing: StorageTransferReplacementWatch?
        do {
            existing = try file.load()
        } catch {
            // A receipt we cannot decode can never say anything; drop it.
            remove()
            return .noReceipt
        }
        guard let watch = existing else { return .noReceipt }
        guard let currentGenerationID, currentGenerationID == watch.datasetGenerationID else {
            remove()
            return .superseded
        }
        let serverCounts: [String: Int]
        do {
            serverCounts = try await read()
        } catch {
            guard watch.readFailures < Self.maximumReadFailures else {
                remove()
                return .dropped
            }
            var next = watch
            next.readFailures += 1
            // A receipt we cannot update is a receipt we stop trusting.
            guard (try? file.save(next, replacing: watch)) != nil else {
                remove()
                return .dropped
            }
            return .deferred
        }
        remove()
        let grown = PomoGemStorageSnapshot.cloudModelNames.sorted().filter { model in
            let allowance = max(0, locallyAuthoredSinceCommit[model, default: 0])
            return serverCounts[model, default: 0] > watch.committedCounts[model, default: 0] + allowance
        }
        return grown.isEmpty ? .cleared : .lateArrival(models: grown)
    }

    /// Deletes exactly this receipt and nothing else, ever.
    private func remove() { try? file.removeReceipt() }
}

extension StorageTransferStateFile {
    /// Removes this one receipt. Refuses to follow a symbolic link and refuses
    /// to unlink anything that is not a regular file, so a tampered path can
    /// never turn a diagnostic into a deletion.
    func removeReceipt() throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else { throw StorageTransferError.unsafePath }
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw StorageTransferError.unsafePath }
        guard unlink(url.path) == 0 || errno == ENOENT else { throw StorageTransferError.unsafePath }
    }
}
