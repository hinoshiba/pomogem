import Darwin
import Foundation

enum CloudOfflineAccessOrigin: String, Codable, Equatable, Sendable {
    case verifiedOnline, legacySuccessfulMount, revokedWithoutBaseline
}

/// A bounded local receipt, not an Apple credential. Legacy adoption preserves
/// a local reset observation without claiming a new online check. A nil dataset
/// is a known legacy generation only when isDatasetGenerationKnown is true.
struct CloudOfflineAccessReceipt: Equatable, Sendable {
    let revisionID: UUID
    let binding: ActiveAccountLocalBinding
    let origin: CloudOfflineAccessOrigin
    let isDatasetGenerationKnown: Bool
    let datasetGenerationID: UUID?
    let resetBaseline: ActivityResetSnapshot?
    let wasUsedOffline: Bool
    let revocation: CloudOfflineRevocationReason?

    var hasVerifiedOnlineBaseline: Bool { origin == .verifiedOnline }

    func validate() throws {
        guard AppleAccountFingerprint.isValid(binding.accountFingerprint),
              isDatasetGenerationKnown || datasetGenerationID == nil
        else { throw CloudOfflineAccessStateError.invalidReceipt }
        switch origin {
        case .verifiedOnline:
            guard isDatasetGenerationKnown else { throw CloudOfflineAccessStateError.invalidReceipt }
        case .legacySuccessfulMount:
            // Adoption itself records offline use before any user writer is
            // published. Unknown lineage never becomes known through a read.
            guard wasUsedOffline else { throw CloudOfflineAccessStateError.invalidReceipt }
        case .revokedWithoutBaseline:
            guard !isDatasetGenerationKnown, datasetGenerationID == nil,
                  resetBaseline == nil, !wasUsedOffline, revocation != nil else {
                throw CloudOfflineAccessStateError.invalidReceipt
            }
        }
        if let marker = resetBaseline {
            guard ActivityResetPolicy.isSupported(marker),
                  marker.resetAt.timeIntervalSinceReferenceDate.isFinite,
                  marker.writerDeviceID.utf8.count <= 16_384 else {
                throw CloudOfflineAccessStateError.invalidReceipt
            }
        }
    }
}

enum CloudOfflineAccessStateError: Error, Equatable {
    case invalidReceipt, unsafeDirectory, staleReceipt
}

// All keys, including explicit nulls, are required. Do not silently drop new
// fields from a future authority format when an older app decodes this file.
extension CloudOfflineAccessReceipt: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case formatVersion, revisionID, namespace, accountFingerprint
        case origin, isDatasetGenerationKnown, hasVerifiedOnlineBaseline, datasetGenerationID, resetBaseline
        case wasUsedOffline, revocation
    }

    init(from decoder: Decoder) throws {
        try CloudOfflineStrictKeys.require(CodingKeys.allCases.map(\.rawValue), from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .formatVersion) == 1 else {
            throw CloudOfflineAccessStateError.invalidReceipt
        }
        let namespaceString = try values.decode(String.self, forKey: .namespace)
        guard let namespace = AccountDataNamespace(rawValue: namespaceString),
              namespace.rawValue == namespaceString,
              let binding = ActiveAccountLocalBinding(namespace: namespace,
                accountFingerprint: try values.decode(String.self, forKey: .accountFingerprint)) else {
            throw CloudOfflineAccessStateError.invalidReceipt
        }
        self.init(revisionID: try values.decode(UUID.self, forKey: .revisionID), binding: binding,
            origin: try values.decode(CloudOfflineAccessOrigin.self, forKey: .origin),
            isDatasetGenerationKnown: try values.decode(Bool.self, forKey: .isDatasetGenerationKnown),
            datasetGenerationID: try values.decodeIfPresent(UUID.self, forKey: .datasetGenerationID),
            resetBaseline: try values.decodeIfPresent(CloudOfflineResetBaseline.self, forKey: .resetBaseline)?.snapshot,
            wasUsedOffline: try values.decode(Bool.self, forKey: .wasUsedOffline),
            revocation: try values.decodeIfPresent(CloudOfflineRevocationReason.self, forKey: .revocation))
        guard try values.decode(Bool.self, forKey: .hasVerifiedOnlineBaseline) == hasVerifiedOnlineBaseline else {
            throw CloudOfflineAccessStateError.invalidReceipt
        }
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .formatVersion)
        try values.encode(revisionID, forKey: .revisionID)
        try values.encode(binding.namespace.rawValue, forKey: .namespace)
        try values.encode(binding.accountFingerprint, forKey: .accountFingerprint)
        try values.encode(origin, forKey: .origin)
        try values.encode(isDatasetGenerationKnown, forKey: .isDatasetGenerationKnown)
        try values.encode(hasVerifiedOnlineBaseline, forKey: .hasVerifiedOnlineBaseline)
        try values.encode(datasetGenerationID, forKey: .datasetGenerationID)
        try values.encode(resetBaseline.map(CloudOfflineResetBaseline.init), forKey: .resetBaseline)
        try values.encode(wasUsedOffline, forKey: .wasUsedOffline)
        try values.encode(revocation, forKey: .revocation)
    }
}

private struct CloudOfflineStrictKeys: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }

    static func require(_ names: [String], from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Self.self)
        guard Set(values.allKeys.map(\.stringValue)) == Set(names) else {
            throw CloudOfflineAccessStateError.invalidReceipt
        }
    }
}

private struct CloudOfflineResetBaseline: Codable {
    let snapshot: ActivityResetSnapshot

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, epochID, sequence, resetAtBits, writerDeviceID
    }

    init(_ snapshot: ActivityResetSnapshot) { self.snapshot = snapshot }

    init(from decoder: Decoder) throws {
        try CloudOfflineStrictKeys.require(CodingKeys.allCases.map(\.rawValue), from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = ActivityResetSnapshot(id: try values.decode(UUID.self, forKey: .id),
            epochID: try values.decode(UUID.self, forKey: .epochID),
            sequence: try values.decode(Int.self, forKey: .sequence),
            resetAt: Date(timeIntervalSinceReferenceDate: Double(bitPattern:
                try values.decode(UInt64.self, forKey: .resetAtBits))),
            writerDeviceID: try values.decode(String.self, forKey: .writerDeviceID))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(snapshot.id, forKey: .id)
        try values.encode(snapshot.epochID, forKey: .epochID)
        try values.encode(snapshot.sequence, forKey: .sequence)
        try values.encode(snapshot.resetAt.timeIntervalSinceReferenceDate.bitPattern, forKey: .resetAtBits)
        try values.encode(snapshot.writerDeviceID, forKey: .writerDeviceID)
    }
}

/// MainActor serialization plus receipt CAS prevent a delayed online mount from
/// clearing revocation recorded while it was suspended. Callers still validate
/// their live mount/scene lease before the synchronous receipt commit.
@MainActor
struct CloudOfflineAccessState {
    let directory: URL
    private let directoryAnchor: URL

    init(directory: URL? = nil) throws {
        if let directory {
            try self.init(directory: directory, anchor: URL(fileURLWithPath: "/", isDirectory: true))
        } else {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw CloudOfflineAccessStateError.unsafeDirectory
            }
            try self.init(applicationSupportDirectory: support,
                sandboxRoot: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        }
    }

    /// These roots come from the OS in production. Only aliases above the
    /// sandbox boundary may be followed; resolving the whole support path
    /// would also hide a link inside an app-owned directory. The explicit
    /// arguments let tests reproduce an OS alias without changing /var.
    init(applicationSupportDirectory: URL, sandboxRoot: URL) throws {
        guard applicationSupportDirectory.isFileURL, sandboxRoot.isFileURL else {
            throw CloudOfflineAccessStateError.unsafeDirectory
        }
        let support = applicationSupportDirectory.standardizedFileURL
        let root = sandboxRoot.standardizedFileURL
        guard support.pathComponents.count > root.pathComponents.count,
              support.pathComponents.starts(with: root.pathComponents) else {
            throw CloudOfflineAccessStateError.unsafeDirectory
        }
        try self.init(directory: support.appendingPathComponent("CloudOffline", isDirectory: true), anchor: root)
    }

    private init(directory: URL, anchor: URL) throws {
        guard directory.isFileURL else { throw CloudOfflineAccessStateError.unsafeDirectory }
        self.directory = directory.standardizedFileURL
        directoryAnchor = anchor
        try prepareDirectory()
    }

    func load() throws -> CloudOfflineAccessReceipt? {
        let value = try stateFile().load()
        try value?.validate()
        return value
    }

    /// Call only after exact live account, dataset/history, schema, complete
    /// pair and successful cloud mount checks. This is the only operation that
    /// clears offline-session use, and the only one that can clear ANY
    /// revocation; it is never called by an offline open.
    /// `clearRevocationAfterConfirmedIdentity` can retract the narrower set of
    /// revocations that a comparison never produced, and nothing else may. This is a mount observation, never an upload acknowledgement:
    /// later mirror construction must check history even when wasUsedOffline is
    /// false, because native persistent history may still contain unsent work.
    @discardableResult
    func recordVerifiedOnline(
        binding: ActiveAccountLocalBinding,
        datasetGenerationID: UUID?,
        resetBaseline: ActivityResetSnapshot?,
        expectedReceipt: CloudOfflineAccessReceipt?
    ) throws -> CloudOfflineAccessReceipt {
        guard try load() == expectedReceipt else { throw CloudOfflineAccessStateError.staleReceipt }
        let value = CloudOfflineAccessReceipt(revisionID: UUID(), binding: binding,
            origin: .verifiedOnline, isDatasetGenerationKnown: true, datasetGenerationID: datasetGenerationID,
            resetBaseline: resetBaseline, wasUsedOffline: false, revocation: nil)
        try value.validate()
        try stateFile().save(value, replacing: expectedReceipt)
        return value
    }

    /// Migrate only a previously mounted closed pair from a version that had
    /// no offline receipt. The caller reads resetBaseline through its unexposed
    /// `.none` reader and passes a prior Runtime admission if one exists. This
    /// does not certify current CloudKit identity, remote history or lineage.
    @discardableResult
    func adoptLegacyMountedCopy(
        binding: ActiveAccountLocalBinding,
        resetBaseline: ActivityResetSnapshot?,
        datasetGenerationID: UUID?,
        isDatasetGenerationKnown: Bool,
        conditions: CloudOfflineAccessConditions,
        expectedReceipt: CloudOfflineAccessReceipt?
    ) throws -> CloudOfflineAccessReceipt {
        guard expectedReceipt == nil, try load() == nil else { throw CloudOfflineAccessStateError.staleReceipt }
        if let reason = CloudOfflineAccessPolicy.legacyAdoptionBlockReason(conditions: conditions, receipt: nil) { throw reason }
        guard conditions.selection == .selected(.cloud(binding: binding)) else {
            throw CloudOfflineAccessBlockReason.bindingMismatch
        }
        let value = CloudOfflineAccessReceipt(revisionID: UUID(), binding: binding,
            origin: .legacySuccessfulMount, isDatasetGenerationKnown: isDatasetGenerationKnown,
            datasetGenerationID: datasetGenerationID, resetBaseline: resetBaseline,
            wasUsedOffline: true, revocation: nil)
        try value.validate()
        try stateFile().save(value, replacing: nil)
        return value
    }

    /// Persist before exposing any `.none` context capable of saving. The last
    /// online reset/dataset baseline deliberately survives all offline saves.
    @discardableResult
    func markOfflineOpened(
        binding: ActiveAccountLocalBinding,
        conditions: CloudOfflineAccessConditions
    ) throws -> CloudOfflineAccessReceipt {
        let previous = try load()
        if let reason = CloudOfflineAccessPolicy.blockReason(conditions: conditions, receipt: previous) { throw reason }
        guard let previous, previous.binding == binding else { throw CloudOfflineAccessBlockReason.bindingMismatch }
        let value = CloudOfflineAccessReceipt(revisionID: UUID(), binding: binding,
            origin: previous.origin, isDatasetGenerationKnown: previous.isDatasetGenerationKnown,
            datasetGenerationID: previous.datasetGenerationID,
            resetBaseline: previous.resetBaseline, wasUsedOffline: true, revocation: nil)
        try stateFile().save(value, replacing: previous)
        return value
    }

    /// Persist even before the first online receipt. Repeat notifications get a
    /// new revision so an earlier async verification cannot erase the event.
    func revoke(binding: ActiveAccountLocalBinding, reason: CloudOfflineRevocationReason) throws {
        let previous = try load()
        guard previous == nil || previous?.binding == binding else { throw CloudOfflineAccessBlockReason.bindingMismatch }
        let value = CloudOfflineAccessReceipt(revisionID: UUID(), binding: binding,
            origin: previous?.origin ?? .revokedWithoutBaseline,
            isDatasetGenerationKnown: previous?.isDatasetGenerationKnown ?? false,
            datasetGenerationID: previous?.datasetGenerationID,
            resetBaseline: previous?.resetBaseline, wasUsedOffline: previous?.wasUsedOffline ?? false,
            revocation: reason)
        try stateFile().save(value, replacing: previous)
    }

    /// Retract a revocation that was never evidence of a different account.
    ///
    /// `confirmedBinding` must come from a COMPLETED online boundary
    /// resolution: a verified account fingerprint that the namespace registry
    /// resolved to exactly this binding. When the receipt is bound to that
    /// same account and its revocation is one
    /// `CloudOfflineAccessPolicy.isRetractableByConfirmedIdentity` allows,
    /// the revocation is dropped and everything else in the receipt — origin,
    /// dataset lineage, reset baseline, prior offline use — is preserved
    /// unchanged. A fresh revision invalidates any suspended verification, so
    /// a late writer cannot resurrect the retracted state, and compare-and-
    /// swap makes a concurrent revocation win.
    ///
    /// This does not certify CloudKit lineage, remote history or a mount, and
    /// it never creates a baseline: a receipt written before any online check
    /// (`revokedWithoutBaseline`) has nothing to return to and is left alone.
    /// Returns nil when nothing was retracted.
    @discardableResult
    func clearRevocationAfterConfirmedIdentity(
        confirmedBinding: ActiveAccountLocalBinding
    ) throws -> CloudOfflineAccessReceipt? {
        let previous = try load()
        guard let previous, previous.binding == confirmedBinding,
              previous.origin != .revokedWithoutBaseline,
              let reason = previous.revocation,
              CloudOfflineAccessPolicy.isRetractableByConfirmedIdentity(reason) else { return nil }
        let value = CloudOfflineAccessReceipt(revisionID: UUID(), binding: previous.binding,
            origin: previous.origin, isDatasetGenerationKnown: previous.isDatasetGenerationKnown,
            datasetGenerationID: previous.datasetGenerationID,
            resetBaseline: previous.resetBaseline, wasUsedOffline: previous.wasUsedOffline,
            revocation: nil)
        try value.validate()
        try stateFile().save(value, replacing: previous)
        return value
    }

    private func stateFile() throws -> StorageTransferStateFile<CloudOfflineAccessReceipt> {
        try prepareDirectory()
        return try StorageTransferStateFile(url: directory.appendingPathComponent("access-v1.json"))
    }

    /// The sandbox root must already exist and cannot itself be a link. Check
    /// every owned component below it, including on later receipt accesses.
    /// OS-owned ancestors such as /var are outside this trust boundary.
    private func prepareDirectory() throws {
        var current = directoryAnchor
        var anchorInfo = stat()
        guard lstat(current.path, &anchorInfo) == 0,
              (anchorInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw CloudOfflineAccessStateError.unsafeDirectory
        }
        for component in directory.pathComponents.dropFirst(directoryAnchor.pathComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(current.path, &info) != 0 {
                guard errno == ENOENT else { throw CloudOfflineAccessStateError.unsafeDirectory }
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                try synchronize(current)
                try synchronize(current.deletingLastPathComponent())
            }
            guard lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw CloudOfflineAccessStateError.unsafeDirectory
            }
        }
    }

    private func synchronize(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CloudOfflineAccessStateError.unsafeDirectory }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CloudOfflineAccessStateError.unsafeDirectory }
    }
}
