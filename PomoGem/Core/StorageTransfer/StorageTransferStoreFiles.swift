import CryptoKit
import Darwin
import Foundation

enum StorageTransferStoreFileError: Error, LocalizedError, Equatable {
    case unsafeArtifact, incompleteFamily, changedArtifact, invalidManifest, limitExceeded
    var errorDescription: String? {
        "保存領域のコピーを安全に確認できませんでした。元のデータを保持して切り替えを停止しました。"
    }
}

struct StorageTransferArtifactManifest: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case file, directory }
    struct Entry: Codable, Sendable, Equatable {
        let relativePath: String
        let kind: Kind
        let byteCount: Int64
        let sha256: String?
    }
    let formatVersion: Int
    let transactionID: UUID
    let selection: PersistenceDeploymentSelection
    let entries: [Entry]
}

/// The runtime must retire every container that can touch these paths before
/// calling this helper and keep them retired until promotion completes. A file
/// manifest proves bytes and paths; it cannot prove SQLite/mirroring quiescence.
/// Original stores are never renamed, overwritten, or deleted by this API.
@MainActor
struct StorageTransferStoreFiles {
    enum Location { case source, frozen, staged }
    private static let maximumEntries = 50_000
    private static let maximumBytes: Int64 = 1_024 * 1_024 * 1_024
    private static let maximumManifestBytes = 16 * 1_024 * 1_024
    let transactionID: UUID
    let transactionDirectory: URL
    let snapshotURL: URL
    private let sourceDirectory: URL

    init(transactionID: UUID, transferRoot: URL? = nil, storeDirectory: URL? = nil) throws {
        self.transactionID = transactionID
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let root = (transferRoot ?? support.appendingPathComponent("StorageTransfer", isDirectory: true)).standardizedFileURL
        transactionDirectory = root.appendingPathComponent(transactionID.uuidString.lowercased(), isDirectory: true)
        snapshotURL = transactionDirectory.appendingPathComponent("payload-v1.json")
        sourceDirectory = (storeDirectory ?? PersistenceStoreTopology.localOnlyPersistentStoreURLs(namespace: AccountDataNamespace())[0].deletingLastPathComponent()).standardizedFileURL
        try Self.requireDirectory(root, create: true)
        try Self.requireDirectory(transactionDirectory, create: true)
        try Self.requireDirectory(sourceDirectory, create: false)
    }

    func storeURLs(for selection: PersistenceDeploymentSelection, location: Location) -> [URL] {
        let directory = directory(for: location)
        switch selection {
        case .cloud(let binding):
            return PersistenceStoreTopology.accountStoreURLs(accountNamespace: binding.namespace, directory: directory)
        case .localOnly(let namespace):
            return PersistenceStoreTopology.localOnlyPersistentStoreURLs(namespace: namespace, directory: directory)
        }
    }

    func loadFrozenManifest(selection: PersistenceDeploymentSelection) throws -> StorageTransferArtifactManifest? {
        try loadManifest("frozen-manifest-v1.json", selection: selection)
    }

    func loadStagedManifest(destination: PersistenceDeploymentSelection) throws -> StorageTransferArtifactManifest? {
        try loadManifest("staged-manifest-v1.json", selection: destination)
    }

    /// An existing durable manifest is always the baseline on retry. A partial
    /// copy or a subsequently changed source can never redefine that baseline.
    func freeze(selection: PersistenceDeploymentSelection) throws -> StorageTransferArtifactManifest {
        let expected: StorageTransferArtifactManifest
        if let existing = try loadFrozenManifest(selection: selection) { expected = existing }
        else {
            let entries = try inventory(selection: selection, directory: sourceDirectory, exclusive: false)
            expected = StorageTransferArtifactManifest(formatVersion: 1, transactionID: transactionID, selection: selection, entries: entries)
            try validate(expected, selection: selection)
            try writeManifest(expected, name: "frozen-manifest-v1.json")
        }
        try requireInventory(expected, directory: sourceDirectory, exclusive: false)
        let frozen = directory(for: .frozen)
        try Self.requireDirectory(frozen, create: true)
        let roots = rootNames(expected)
        try requireOnlyRoots(roots, in: frozen)
        let temporary = transactionDirectory.appendingPathComponent("copy-pending", isDirectory: true)
        try Self.requireDirectory(temporary, create: true)
        try requireOnlyRoots(roots, in: temporary)
        for root in roots.sorted() {
            try Task.checkCancellation()
            let destination = frozen.appendingPathComponent(root)
            if try Self.type(destination) != nil {
                try requireRoot(root, expected: expected, directory: frozen)
                continue
            }
            let pending = temporary.appendingPathComponent(root)
            if try Self.type(pending) != nil {
                // This is only the named transaction-owned interrupted copy.
                // Refuse links/devices anywhere inside before removing it.
                _ = try entries(under: pending, relativePath: root)
                try FileManager.default.removeItem(at: pending)
                try Self.synchronizeDirectory(temporary)
            }
            let source = sourceDirectory.appendingPathComponent(root)
            try FileManager.default.copyItem(at: source, to: pending)
            try requireRoot(root, expected: expected, directory: temporary)
            try synchronizeTree(pending)
            try moveExclusive(pending, to: destination)
        }
        try requireInventory(expected, directory: frozen, exclusive: true)
        try requireInventory(expected, directory: sourceDirectory, exclusive: false)
        return expected
    }

    /// SwiftData may checkpoint a logically read-only .none mount. Give each
    /// reader its own disposable copy so the sealed frozen backup stays exact.
    /// Reader directories survive failures until the runtime retires all their
    /// containers and performs separately authorized transaction cleanup.
    func makeFrozenReaderCopy(selection: PersistenceDeploymentSelection) throws -> [URL] {
        let manifest = try freeze(selection: selection)
        return try makeReaderCopy(manifest: manifest, source: directory(for: .frozen))
    }

    /// A closed, not-yet-sealed destination can be verified without opening
    /// the original staged files. A prior seal remains authoritative if present.
    func makeStagedReaderCopy(destination: PersistenceDeploymentSelection) throws -> [URL] {
        let staged = directory(for: .staged)
        let manifest: StorageTransferArtifactManifest
        if let sealed = try loadStagedManifest(destination: destination) {
            try requireInventory(sealed, directory: staged, exclusive: true)
            manifest = sealed
        } else {
            manifest = StorageTransferArtifactManifest(formatVersion: 1, transactionID: transactionID,
                selection: destination, entries: try inventory(selection: destination, directory: staged, exclusive: true))
            try validate(manifest, selection: destination)
        }
        return try makeReaderCopy(manifest: manifest, source: staged)
    }

    /// The committed journal is required in addition to the runtime's container
    /// retirement gate. A partial deletion resumes only against this immutable
    /// intent, and the sealed frozen backup is retained for later cleanup.
    func retireSource(selection: PersistenceDeploymentSelection) throws {
        let journalStore = StorageTransferJournalStore(directory: transactionDirectory.deletingLastPathComponent())
        guard let journal = try journalStore.load(), journal.transactionID == transactionID,
              journal.source == selection, journal.phase >= .selectionCommitted,
              try journalStore.committedSelection() == StorageTransferCommittedSelection(journal: journal),
              let frozen = try loadFrozenManifest(selection: selection) else {
            throw StorageTransferError.staleTransaction
        }
        try requireInventory(frozen, directory: directory(for: .frozen), exclusive: true)
        let name = "source-retirement-v1.json"
        let intent: StorageTransferArtifactManifest
        if let existing = try loadManifest(name, selection: selection) {
            guard existing == frozen else { throw StorageTransferStoreFileError.invalidManifest }
            intent = existing
        } else {
            try requireInventory(frozen, directory: sourceDirectory, exclusive: false)
            try writeManifest(frozen, name: name)
            intent = frozen
        }
        try removeRemaining(intent: intent, directory: sourceDirectory, exclusive: false)
    }

    /// Only an unacknowledged .none import target may be discarded. Persist an
    /// exact partial-family intent first; a crash cannot broaden that deletion.
    func discardUnacknowledgedStaged(destination: PersistenceDeploymentSelection) throws {
        let store = StorageTransferJournalStore(directory: transactionDirectory.deletingLastPathComponent())
        guard let journal = try store.load(), journal.transactionID == transactionID,
              journal.destination == destination, journal.phase <= .preparingDestination,
              try loadStagedManifest(destination: destination) == nil else {
            throw StorageTransferError.staleTransaction
        }
        let checkpointFile = try StorageTransferStateFile<StorageTransferRuntimeCheckpoint>(
            url: transactionDirectory.appendingPathComponent("runtime-v1.json"))
        if let checkpoint = try checkpointFile.load() {
            try checkpoint.validate(journal: journal)
            guard checkpoint.importedPayloadDigest == nil, checkpoint.verifiedCloudPayloadDigest == nil else {
                throw StorageTransferError.staleTransaction
            }
        }
        let staged = directory(for: .staged)
        guard try Self.type(staged) != nil else { return }
        try Self.requireDirectory(staged, create: false)
        let name = "staged-discard-v1.json"
        let intent: StorageTransferArtifactManifest
        if let existing = try loadManifest(name, selection: destination, allowIncompleteFamily: true) {
            intent = existing
        } else {
            let entries = try inventory(selection: destination, directory: staged,
                exclusive: true, allowIncompleteFamily: true)
            intent = StorageTransferArtifactManifest(formatVersion: 1, transactionID: transactionID,
                selection: destination, entries: entries)
            try validate(intent, selection: destination, allowIncompleteFamily: true)
            try writeManifest(intent, name: name)
        }
        try removeRemaining(intent: intent, directory: staged, exclusive: true)
        // Only a verified empty stage ends this attempt. A later failed import
        // may create a different unacknowledged partial family under this same
        // still-pending journal; it needs its own fresh durable discard intent.
        try FileManager.default.removeItem(at: transactionDirectory.appendingPathComponent(name))
        try Self.synchronizeDirectory(transactionDirectory)
    }

    private func makeReaderCopy(manifest: StorageTransferArtifactManifest, source: URL) throws -> [URL] {
        let root = transactionDirectory.appendingPathComponent("reader", isDirectory: true)
        try Self.requireDirectory(root, create: true)
        let reader = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        guard try Self.type(reader) == nil else { throw StorageTransferStoreFileError.unsafeArtifact }
        try Self.requireDirectory(reader, create: true)
        for name in rootNames(manifest).sorted() {
            try Task.checkCancellation()
            let destination = reader.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: destination)
            try requireRoot(name, expected: manifest, directory: reader)
            try synchronizeTree(destination)
        }
        try requireInventory(manifest, directory: reader, exclusive: true)
        try requireInventory(manifest, directory: source, exclusive: true)
        return storeURLs(for: manifest.selection, location: .frozen).map {
            reader.appendingPathComponent($0.lastPathComponent, isDirectory: false)
        }
    }

    /// Call after closing the newly imported destination containers. Returning
    /// an existing manifest revalidates it, never captures a new version.
    func sealStaged(destination: PersistenceDeploymentSelection) throws -> StorageTransferArtifactManifest {
        if let existing = try loadStagedManifest(destination: destination) {
            try requireInventory(existing, directory: directory(for: .staged), exclusive: true)
            return existing
        }
        let staged = directory(for: .staged)
        let entries = try inventory(selection: destination, directory: staged, exclusive: true)
        let manifest = StorageTransferArtifactManifest(formatVersion: 1, transactionID: transactionID, selection: destination, entries: entries)
        try validate(manifest, selection: destination)
        for root in rootNames(manifest) { try synchronizeTree(staged.appendingPathComponent(root)) }
        try writeManifest(manifest, name: "staged-manifest-v1.json")
        return manifest
    }

    /// Each top-level artifact is moved atomically. A crash between artifacts
    /// leaves an exact union of staged and final roots. Retry requires that
    /// union to match the *previously sealed* manifest before moving anything.
    func promoteStaged(destination: PersistenceDeploymentSelection,
                       manifest: StorageTransferArtifactManifest) throws {
        try validate(manifest, selection: destination)
        guard try loadStagedManifest(destination: destination) == manifest else {
            throw StorageTransferStoreFileError.invalidManifest
        }
        let staged = directory(for: .staged)
        try Self.requireDirectory(staged, create: false)
        let roots = rootNames(manifest)
        try requireOnlyRoots(roots, in: staged)
        try rejectUnexpectedSiblings(selection: destination, directory: sourceDirectory)
        for name in layout(selection: destination, directory: sourceDirectory).keys where !roots.contains(name) {
            guard try Self.type(sourceDirectory.appendingPathComponent(name)) == nil else {
                throw StorageTransferStoreFileError.changedArtifact
            }
        }
        for root in roots {
            let inStage = try Self.type(staged.appendingPathComponent(root)) != nil
            let inFinal = try Self.type(sourceDirectory.appendingPathComponent(root)) != nil
            guard inStage != inFinal else { throw StorageTransferStoreFileError.changedArtifact }
            try requireRoot(root, expected: manifest, directory: inStage ? staged : sourceDirectory)
        }
        for root in roots.sorted() {
            try Task.checkCancellation()
            let source = staged.appendingPathComponent(root)
            if try Self.type(source) == nil {
                try requireRoot(root, expected: manifest, directory: sourceDirectory)
                continue
            }
            try requireRoot(root, expected: manifest, directory: staged)
            try moveExclusive(source, to: sourceDirectory.appendingPathComponent(root))
        }
        try requireOnlyRoots([], in: staged)
        try requireInventory(manifest, directory: sourceDirectory, exclusive: false)
    }

    private func directory(for location: Location) -> URL {
        switch location {
        case .source: sourceDirectory
        case .frozen: transactionDirectory.appendingPathComponent("frozen", isDirectory: true)
        case .staged: transactionDirectory.appendingPathComponent("staged", isDirectory: true)
        }
    }

    private func layout(selection: PersistenceDeploymentSelection, directory: URL) -> [String: PersistenceStoreArtifactLayout.Variant] {
        let stores: [URL]
        switch selection {
        case .cloud(let binding): stores = PersistenceStoreTopology.accountStoreURLs(accountNamespace: binding.namespace, directory: directory)
        case .localOnly(let namespace): stores = PersistenceStoreTopology.localOnlyPersistentStoreURLs(namespace: namespace, directory: directory)
        }
        var result: [String: PersistenceStoreArtifactLayout.Variant] = [:]
        for store in stores {
            for (url, variant) in zip(PersistenceStoreArtifactLayout.artifacts(for: store), PersistenceStoreArtifactLayout.variants) {
                result[url.lastPathComponent] = variant
            }
        }
        return result
    }

    private func inventory(selection: PersistenceDeploymentSelection, directory: URL, exclusive: Bool,
                           allowIncompleteFamily: Bool = false) throws -> [StorageTransferArtifactManifest.Entry] {
        try Self.requireDirectory(directory, create: false)
        try rejectUnexpectedSiblings(selection: selection, directory: directory)
        let allowed = layout(selection: selection, directory: directory)
        if exclusive { try requireOnlyRoots(Set(allowed.keys), in: directory) }
        var result: [StorageTransferArtifactManifest.Entry] = []
        var bytes: Int64 = 0
        for name in allowed.keys.sorted() {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(name)
            guard let kind = try Self.type(url) else {
                if !allowIncompleteFamily, allowed[name]?.isPrimaryStore == true { throw StorageTransferStoreFileError.incompleteFamily }
                continue
            }
            guard (kind == .directory) == allowed[name]?.isDirectory else { throw StorageTransferStoreFileError.unsafeArtifact }
            let values = try entries(under: url, relativePath: name)
            guard values.count <= Self.maximumEntries - result.count else { throw StorageTransferStoreFileError.limitExceeded }
            for value in values {
                guard value.byteCount <= Self.maximumBytes - bytes else { throw StorageTransferStoreFileError.limitExceeded }
                bytes += value.byteCount
            }
            result.append(contentsOf: values)
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func entries(under root: URL, relativePath: String) throws -> [StorageTransferArtifactManifest.Entry] {
        var result: [StorageTransferArtifactManifest.Entry] = []
        var pending: [(URL, String)] = [(root, relativePath)]
        var bytes: Int64 = 0
        while let (url, relative) = pending.popLast() {
            try Task.checkCancellation()
            guard result.count < Self.maximumEntries, let kind = try Self.type(url) else { throw StorageTransferStoreFileError.limitExceeded }
            if kind == .directory {
                result.append(.init(relativePath: relative, kind: .directory, byteCount: 0, sha256: nil))
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                guard children.count <= Self.maximumEntries - result.count - pending.count else { throw StorageTransferStoreFileError.limitExceeded }
                for child in children { pending.append((child, relative + "/" + child.lastPathComponent)) }
            } else {
                let file = try Self.hashFile(url)
                guard file.bytes <= Self.maximumBytes - bytes else { throw StorageTransferStoreFileError.limitExceeded }
                bytes += file.bytes
                result.append(.init(relativePath: relative, kind: .file, byteCount: file.bytes, sha256: file.sha256))
            }
        }
        return result.sorted { $0.relativePath < $1.relativePath }
    }

    private func requireInventory(_ manifest: StorageTransferArtifactManifest, directory: URL, exclusive: Bool) throws {
        guard try inventory(selection: manifest.selection, directory: directory, exclusive: exclusive) == manifest.entries else {
            throw StorageTransferStoreFileError.changedArtifact
        }
    }

    private func requireRoot(_ root: String, expected: StorageTransferArtifactManifest, directory: URL) throws {
        let values = expected.entries.filter { $0.relativePath == root || $0.relativePath.hasPrefix(root + "/") }
        guard try entries(under: directory.appendingPathComponent(root), relativePath: root) == values else {
            throw StorageTransferStoreFileError.changedArtifact
        }
    }

    private func rootNames(_ manifest: StorageTransferArtifactManifest) -> Set<String> {
        Set(manifest.entries.compactMap { $0.relativePath.split(separator: "/").first.map(String.init) })
    }

    private func requireOnlyRoots(_ expected: Set<String>, in directory: URL) throws {
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard Set(children.map(\.lastPathComponent)).isSubset(of: expected) else { throw StorageTransferStoreFileError.unsafeArtifact }
        for child in children { _ = try Self.type(child) }
    }

    private func rejectUnexpectedSiblings(selection: PersistenceDeploymentSelection, directory: URL) throws {
        let allowed = layout(selection: selection, directory: directory)
        let stems = allowed.filter { $0.value.isPrimaryStore }.keys.map { String($0.dropLast(".store".count)) }
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = child.lastPathComponent
            if stems.contains(where: { name.hasPrefix($0) || name.hasPrefix("." + $0) }), allowed[name] == nil {
                throw StorageTransferStoreFileError.unsafeArtifact
            }
        }
    }

    private func validate(_ manifest: StorageTransferArtifactManifest, selection: PersistenceDeploymentSelection,
                          allowIncompleteFamily: Bool = false) throws {
        guard manifest.formatVersion == 1, manifest.transactionID == transactionID,
              manifest.selection == selection, manifest.entries.count <= Self.maximumEntries,
              manifest.entries == manifest.entries.sorted(by: { $0.relativePath < $1.relativePath }),
              Set(manifest.entries.map(\.relativePath)).count == manifest.entries.count else { throw StorageTransferStoreFileError.invalidManifest }
        let allowed = layout(selection: selection, directory: sourceDirectory)
        let byPath = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.relativePath, $0) })
        var bytes: Int64 = 0
        for entry in manifest.entries {
            let parts = entry.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
                  let first = parts.first, let variant = allowed[String(first)],
                  entry.byteCount >= 0, entry.byteCount <= Self.maximumBytes - bytes else { throw StorageTransferStoreFileError.invalidManifest }
            bytes += entry.byteCount
            if parts.count == 1 {
                guard (entry.kind == .directory) == variant.isDirectory else { throw StorageTransferStoreFileError.invalidManifest }
            } else {
                let parent = parts.dropLast().joined(separator: "/")
                guard byPath[parent]?.kind == .directory else { throw StorageTransferStoreFileError.invalidManifest }
            }
            switch entry.kind {
            case .directory: guard entry.byteCount == 0, entry.sha256 == nil else { throw StorageTransferStoreFileError.invalidManifest }
            case .file: guard entry.sha256.map(AppleAccountFingerprint.isValid) == true else { throw StorageTransferStoreFileError.invalidManifest }
            }
        }
        guard allowIncompleteFamily || allowed.filter({ $0.value.isPrimaryStore }).keys.allSatisfy({ byPath[$0]?.kind == .file }) else {
            throw StorageTransferStoreFileError.incompleteFamily
        }
    }

    private func loadManifest(_ name: String, selection: PersistenceDeploymentSelection,
                             allowIncompleteFamily: Bool = false) throws -> StorageTransferArtifactManifest? {
        let url = transactionDirectory.appendingPathComponent(name)
        guard let kind = try Self.type(url) else { return nil }
        guard kind == .file else { throw StorageTransferStoreFileError.invalidManifest }
        let file = try Self.hashFile(url)
        guard file.bytes <= Self.maximumManifestBytes else { throw StorageTransferStoreFileError.limitExceeded }
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard Int64(data.count) == file.bytes, digest == file.sha256 else { throw StorageTransferStoreFileError.changedArtifact }
        let manifest = try JSONDecoder().decode(StorageTransferArtifactManifest.self, from: data)
        try validate(manifest, selection: selection, allowIncompleteFamily: allowIncompleteFamily)
        return manifest
    }

    private func removeRemaining(intent: StorageTransferArtifactManifest, directory: URL, exclusive: Bool) throws {
        let remaining = try inventory(selection: intent.selection, directory: directory,
            exclusive: exclusive, allowIncompleteFamily: true)
        let expected = Dictionary(uniqueKeysWithValues: intent.entries.map { ($0.relativePath, $0) })
        guard remaining.allSatisfy({ expected[$0.relativePath] == $0 }) else {
            throw StorageTransferStoreFileError.changedArtifact
        }
        let ordered = remaining.sorted {
            let leftDepth = $0.relativePath.split(separator: "/").count
            let rightDepth = $1.relativePath.split(separator: "/").count
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            return $0.relativePath < $1.relativePath
        }
        for entry in ordered {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(entry.relativePath)
            guard try Self.type(url) == entry.kind else { throw StorageTransferStoreFileError.changedArtifact }
            if entry.kind == .file {
                let current = try Self.hashFile(url)
                guard current.bytes == entry.byteCount, current.sha256 == entry.sha256 else { throw StorageTransferStoreFileError.changedArtifact }
                guard unlink(url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            } else {
                // rmdir refuses a concurrently added child instead of deleting
                // content that was not part of the exact original manifest.
                guard rmdir(url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            try Self.synchronizeDirectory(url.deletingLastPathComponent())
        }
        guard try inventory(selection: intent.selection, directory: directory,
            exclusive: exclusive, allowIncompleteFamily: true).isEmpty else { throw StorageTransferStoreFileError.changedArtifact }
    }

    private func writeManifest(_ manifest: StorageTransferArtifactManifest, name: String) throws {
        let url = transactionDirectory.appendingPathComponent(name)
        guard try Self.type(url) == nil else { throw StorageTransferStoreFileError.invalidManifest }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= Self.maximumManifestBytes else { throw StorageTransferStoreFileError.limitExceeded }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try Self.synchronizeFile(url)
        try Self.synchronizeDirectory(transactionDirectory)
        guard try Data(contentsOf: url) == data else { throw StorageTransferStoreFileError.changedArtifact }
    }

    private func moveExclusive(_ source: URL, to destination: URL) throws {
        guard try Self.type(destination) == nil else { throw StorageTransferStoreFileError.changedArtifact }
        // All paths are within Application Support on the same filesystem.
        // RENAME_EXCL also refuses a concurrently introduced destination.
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try Self.synchronizeDirectory(source.deletingLastPathComponent())
        try Self.synchronizeDirectory(destination.deletingLastPathComponent())
    }

    private func synchronizeTree(_ url: URL) throws {
        for entry in try entries(under: url, relativePath: url.lastPathComponent) {
            let tail = entry.relativePath.split(separator: "/").dropFirst().joined(separator: "/")
            let target = tail.isEmpty ? url : url.appendingPathComponent(tail)
            if entry.kind == .file { try Self.synchronizeFile(target) }
        }
        let directories = try entries(under: url, relativePath: url.lastPathComponent).filter { $0.kind == .directory }
        for entry in directories.sorted(by: { $0.relativePath.count > $1.relativePath.count }) {
            let tail = entry.relativePath.split(separator: "/").dropFirst().joined(separator: "/")
            try Self.synchronizeDirectory(tail.isEmpty ? url : url.appendingPathComponent(tail))
        }
        try Self.synchronizeDirectory(url.deletingLastPathComponent())
    }

    private static func type(_ url: URL) throws -> StorageTransferArtifactManifest.Kind? {
        guard url.isFileURL else { throw StorageTransferStoreFileError.unsafeArtifact }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        default: throw StorageTransferStoreFileError.unsafeArtifact
        }
    }

    private static func requireDirectory(_ url: URL, create: Bool) throws {
        if let kind = try type(url) {
            guard kind == .directory else { throw StorageTransferStoreFileError.unsafeArtifact }
        } else {
            guard create else { throw StorageTransferStoreFileError.incompleteFamily }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try synchronizeDirectory(url.deletingLastPathComponent())
        }
    }

    private static func hashFile(_ url: URL) throws -> (bytes: Int64, sha256: String) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StorageTransferStoreFileError.unsafeArtifact }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw StorageTransferStoreFileError.unsafeArtifact }
        var hash = SHA256()
        var count: Int64 = 0
        while let bytes = try handle.read(upToCount: 1_024 * 1_024), !bytes.isEmpty {
            try Task.checkCancellation()
            guard Int64(bytes.count) <= maximumBytes - count else { throw StorageTransferStoreFileError.limitExceeded }
            count += Int64(bytes.count)
            hash.update(data: bytes)
        }
        guard count == info.st_size else { throw StorageTransferStoreFileError.changedArtifact }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func synchronizeFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StorageTransferStoreFileError.unsafeArtifact }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StorageTransferStoreFileError.unsafeArtifact }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
