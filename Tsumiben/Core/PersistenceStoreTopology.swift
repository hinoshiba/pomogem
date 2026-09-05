import Foundation
import SwiftData

struct AppleAccountNamespaceEntry: Codable, Equatable, Sendable {
    let namespace: AccountDataNamespace
}

enum AppleAccountIdentityObservation: Equatable, Sendable {
    case verified(fingerprint: String)
    case offline
    case unavailable
}

enum AppleAccountBoundaryBlockReason: Equatable, Sendable {
    case identityUnavailable
    case accountMismatch
    case invalidVerifiedIdentity
    case invalidStoredRegistry
}

enum AppleAccountBoundaryDecision: Equatable, Sendable {
    case allow(ActiveAccountLocalBinding)
    case block(AppleAccountBoundaryBlockReason)
}

/// Pure account-to-namespace policy. Only a successful online CloudKit account
/// lookup may create or reuse a mapping. Offline and unavailable observations
/// always fail closed, including after a previously verified launch.
struct AppleAccountNamespaceRegistry: Equatable, Sendable {
    private(set) var entries: [String: AppleAccountNamespaceEntry] = [:]

    init() {}

    mutating func resolve(
        _ observation: AppleAccountIdentityObservation,
        expectedBinding: ActiveAccountLocalBinding? = nil,
        makeNamespace: () -> AccountDataNamespace = { AccountDataNamespace() }
    ) -> AppleAccountBoundaryDecision {
        switch observation {
        case let .verified(fingerprint):
            guard AppleAccountFingerprint.isValid(fingerprint) else {
                return .block(.invalidVerifiedIdentity)
            }
            if let expectedBinding,
               expectedBinding.accountFingerprint != fingerprint {
                return .block(.accountMismatch)
            }

            if let existing = entries[fingerprint] {
                guard let binding = ActiveAccountLocalBinding(
                    namespace: existing.namespace,
                    accountFingerprint: fingerprint
                ) else {
                    return .block(.invalidStoredRegistry)
                }
                guard expectedBinding == nil || expectedBinding == binding else {
                    return .block(.invalidStoredRegistry)
                }
                return .allow(binding)
            }

            if let expectedBinding {
                // The immutable deployment profile is the authority for a
                // selected cloud installation. Reconstructing an otherwise
                // empty compatibility registry from that exact profile is
                // safe, and closes the profile-commit/container-mount crash
                // boundary without changing datasets.
                guard entries.isEmpty,
                      !entries.values.contains(where: {
                          $0.namespace == expectedBinding.namespace
                      })
                else {
                    return .block(.invalidStoredRegistry)
                }
                entries[fingerprint] = AppleAccountNamespaceEntry(
                    namespace: expectedBinding.namespace
                )
                return .allow(expectedBinding)
            }

            let namespace = makeNamespace()
            guard !entries.values.contains(where: {
                $0.namespace == namespace
            }),
            let binding = ActiveAccountLocalBinding(
                namespace: namespace,
                accountFingerprint: fingerprint
            ) else {
                return .block(.invalidStoredRegistry)
            }
            entries[fingerprint] = AppleAccountNamespaceEntry(
                namespace: namespace
            )
            return .allow(binding)

        case .offline, .unavailable:
            return .block(.identityUnavailable)
        }
    }
}

extension AppleAccountNamespaceRegistry: Codable {
    private enum CodingKeys: String, CodingKey {
        case entries
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try values.decode(
            [String: AppleAccountNamespaceEntry].self,
            forKey: .entries
        )
        guard entries.keys.allSatisfy(AppleAccountFingerprint.isValid),
              Set(entries.values.map(\.namespace)).count == entries.count
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .entries,
                in: values,
                debugDescription: "Account registry fingerprints and namespaces must be valid and one-to-one."
            )
        }
        self.entries = entries
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(entries, forKey: .entries)
    }
}

enum PersistenceDeploymentSelection: Equatable, Sendable {
    case cloud(binding: ActiveAccountLocalBinding)
    case localOnly(namespace: AccountDataNamespace)
}

extension PersistenceDeploymentSelection: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case namespace
        case cloudBinding
    }

    private enum Mode: String, Codable {
        case cloud
        case localOnly
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Mode.self, forKey: .mode) {
        case .cloud:
            guard !values.contains(.namespace) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .namespace,
                    in: values,
                    debugDescription: "Cloud selection must not contain a local namespace."
                )
            }
            self = .cloud(binding: try values.decode(
                ActiveAccountLocalBinding.self,
                forKey: .cloudBinding
            ))
        case .localOnly:
            guard !values.contains(.cloudBinding) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .cloudBinding,
                    in: values,
                    debugDescription: "Local-only selection must not contain a cloud binding."
                )
            }
            self = .localOnly(namespace: try values.decode(
                AccountDataNamespace.self,
                forKey: .namespace
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .cloud(binding):
            try values.encode(Mode.cloud, forKey: .mode)
            try values.encode(binding, forKey: .cloudBinding)
        case let .localOnly(namespace):
            try values.encode(Mode.localOnly, forKey: .mode)
            try values.encode(namespace, forKey: .namespace)
        }
    }
}

enum PersistenceDeploymentSelectionState: Equatable, Sendable {
    case unselected
    case selected(PersistenceDeploymentSelection)
    case invalid
}

enum PersistenceDeploymentMountState: Equatable, Sendable {
    case unrecorded
    case mounted(PersistenceDeploymentSelection)
    case invalid
}

enum PersistenceDeploymentStateError: LocalizedError, Equatable {
    case selectionAlreadyMade
    case invalidPersistedSelection

    var errorDescription: String? {
        switch self {
        case .selectionAlreadyMade:
            "保存方式はこのバージョンでは変更できません。"
        case .invalidPersistedSelection:
            "保存方式の設定を安全に確認できません。"
        }
    }
}

/// Installation-level storage contract. A local-only choice is intentionally
/// sticky: version 1 never changes it to CloudKit or uploads its rows. Moving
/// to CloudKit requires deleting/reinstalling the app after an optional export.
@MainActor
enum PersistenceDeploymentState {
    private static let selectionKey = "persistence.deployment-selection.v1"
    private static let mountedSelectionKey =
        "persistence.deployment-mounted-selection.v1"

    static func load(
        defaults: UserDefaults = .standard
    ) -> PersistenceDeploymentSelectionState {
        guard let data = defaults.data(forKey: selectionKey) else {
            return .unselected
        }
        guard let selection = try? JSONDecoder().decode(
            PersistenceDeploymentSelection.self,
            from: data
        ) else {
            return .invalid
        }
        return .selected(selection)
    }

    static func select(
        _ selection: PersistenceDeploymentSelection,
        defaults: UserDefaults = .standard
    ) throws {
        switch load(defaults: defaults) {
        case .unselected:
            break
        case let .selected(existing) where existing == selection:
            return
        case .selected:
            throw PersistenceDeploymentStateError.selectionAlreadyMade
        case .invalid:
            throw PersistenceDeploymentStateError.invalidPersistedSelection
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        defaults.set(
            try encoder.encode(selection),
            forKey: selectionKey
        )
    }

    static func loadMountState(
        defaults: UserDefaults = .standard
    ) -> PersistenceDeploymentMountState {
        guard let data = defaults.data(forKey: mountedSelectionKey) else {
            return .unrecorded
        }
        guard let selection = try? JSONDecoder().decode(
            PersistenceDeploymentSelection.self,
            from: data
        ) else {
            return .invalid
        }
        return .mounted(selection)
    }

    /// Records the first successful durable container construction. The
    /// immutable selection is duplicated in the marker so a stale or corrupt
    /// marker can never authorize recreating a missing dataset.
    static func recordSuccessfulMount(
        _ selection: PersistenceDeploymentSelection,
        defaults: UserDefaults = .standard
    ) throws {
        guard load(defaults: defaults) == .selected(selection) else {
            throw PersistenceDeploymentStateError.invalidPersistedSelection
        }
        switch loadMountState(defaults: defaults) {
        case .unrecorded:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            defaults.set(
                try encoder.encode(selection),
                forKey: mountedSelectionKey
            )
        case let .mounted(existing) where existing == selection:
            return
        case .mounted, .invalid:
            throw PersistenceDeploymentStateError.invalidPersistedSelection
        }
    }

}

enum PersistenceDeploymentValidation: Equatable, Sendable {
    case valid
    /// The immutable choice was committed, but the process stopped while
    /// SwiftData was creating its two physical stores. Reopening the exact same
    /// configurations may create the missing peer; no existing artifact is
    /// removed or replaced.
    case resumeInitialMount
    case needsExplicitChoice
    case recoveryRequired
}

extension PersistenceDeploymentState {
    static func validate(
        selectionState: PersistenceDeploymentSelectionState,
        mountState: PersistenceDeploymentMountState,
        artifactHistory: PersistenceArtifactHistory,
        hasCloudRegistryHistory: Bool,
        hasCloudBindingHistory: Bool
    ) -> PersistenceDeploymentValidation {
        switch selectionState {
        case .invalid:
            return .recoveryRequired
        case .unselected:
            return mountState != .unrecorded
                || artifactHistory.hasAnyArtifact
                || hasCloudRegistryHistory
                || hasCloudBindingHistory
                ? .recoveryRequired
                : .needsExplicitChoice
        case let .selected(.cloud(binding)):
            guard mountState == .unrecorded
                    || mountState == .mounted(.cloud(binding: binding)),
                  !artifactHistory.hasInvalidArtifact,
                  artifactHistory.localOnly.isEmpty
            else { return .recoveryRequired }
            guard !artifactHistory.cloud.isEmpty else {
                return mountState == .unrecorded
                    ? .valid
                    : .recoveryRequired
            }
            guard artifactHistory.cloud.count == 1,
                  let artifacts = artifactHistory.cloud[binding.namespace]
            else { return .recoveryRequired }
            if artifacts.hasCompleteStorePair {
                return .valid
            }
            return mountState == .unrecorded
                    && artifacts.hasExactlyOnePrimaryStore
                ? .resumeInitialMount
                : .recoveryRequired
        case let .selected(.localOnly(namespace)):
            guard mountState == .unrecorded
                    || mountState == .mounted(.localOnly(
                        namespace: namespace
                    )),
                  !artifactHistory.hasInvalidArtifact,
                  artifactHistory.cloud.isEmpty,
                  !hasCloudRegistryHistory,
                  !hasCloudBindingHistory
            else { return .recoveryRequired }
            guard !artifactHistory.localOnly.isEmpty else {
                return mountState == .unrecorded
                    ? .valid
                    : .recoveryRequired
            }
            guard artifactHistory.localOnly.count == 1,
                  let artifacts = artifactHistory.localOnly[namespace]
            else { return .recoveryRequired }
            if artifacts.hasCompleteStorePair {
                return .valid
            }
            return mountState == .unrecorded
                    && artifacts.hasExactlyOnePrimaryStore
                ? .resumeInitialMount
                : .recoveryRequired
        }
    }
}

struct PersistenceArtifactHistory: Equatable, Sendable {
    struct NamespaceArtifacts: Equatable, Sendable {
        var hasSourceStore = false
        var hasProjectionStore = false
        var hasAuxiliaryArtifact = false
        var hasMigrationSidecar = false

        var hasCompleteStorePair: Bool {
            hasSourceStore && hasProjectionStore
        }

        var hasExactlyOnePrimaryStore: Bool {
            hasSourceStore != hasProjectionStore
        }
    }

    var cloud: [AccountDataNamespace: NamespaceArtifacts] = [:]
    var localOnly: [AccountDataNamespace: NamespaceArtifacts] = [:]
    var hasInvalidArtifact = false

    var hasAnyArtifact: Bool {
        hasInvalidArtifact
            || !cloud.isEmpty
            || !localOnly.isEmpty
    }

    func hasExactCompleteStorePair(
        for selection: PersistenceDeploymentSelection
    ) -> Bool {
        guard !hasInvalidArtifact else { return false }
        switch selection {
        case let .cloud(binding):
            return localOnly.isEmpty
                && cloud.count == 1
                && cloud[binding.namespace]?.hasCompleteStorePair == true
        case let .localOnly(namespace):
            return cloud.isEmpty
                && localOnly.count == 1
                && localOnly[namespace]?.hasCompleteStorePair == true
        }
    }
}

enum CloudMountAuthorizationDecision: Equatable, Sendable {
    case allow
    case staleGeneration
    case sceneInactive
    case applicationInactive
    case selectionMismatch
    case identityMismatch
}

/// Pure policy applied before and immediately after constructing a CloudKit-
/// backed container. Apple Account changes require leaving the app's active
/// foreground state on iPhone; coupling both lifecycle signals with a launch
/// generation and an independently re-resolved identity closes that boundary.
enum CloudMountAuthorizationPolicy {
    static func evaluate(
        expectedBinding: ActiveAccountLocalBinding,
        verifiedBinding: ActiveAccountLocalBinding,
        selectionState: PersistenceDeploymentSelectionState,
        generationMatches: Bool,
        isSceneActive: Bool,
        isApplicationActive: Bool
    ) -> CloudMountAuthorizationDecision {
        guard generationMatches else { return .staleGeneration }
        guard isSceneActive else { return .sceneInactive }
        guard isApplicationActive else { return .applicationInactive }
        guard selectionState == .selected(.cloud(binding: expectedBinding)) else {
            return .selectionMismatch
        }
        guard verifiedBinding == expectedBinding else {
            return .identityMismatch
        }
        return .allow
    }
}

enum PersistenceContainerRetirementPollDecision: Equatable, Sendable {
    case continueWaiting
    case retired
    case cancelled
    case timedOut
}

/// A poll-count budget keeps account-change quiescence bounded even if a view
/// task accidentally retains the old ModelContainer. Runtime polling uses a
/// fixed interval, so the maximum wall-clock wait is deterministic.
struct PersistenceContainerRetirementPollBudget: Equatable, Sendable {
    private(set) var remainingPolls: Int

    init(maximumPolls: Int) {
        remainingPolls = max(0, maximumPolls)
    }

    mutating func observe(
        isReleased: Bool,
        generationMatches: Bool
    ) -> PersistenceContainerRetirementPollDecision {
        guard generationMatches else { return .cancelled }
        guard !isReleased else { return .retired }
        guard remainingPolls > 0 else { return .timedOut }
        remainingPolls -= 1
        return .continueWaiting
    }
}

/// Owns the physical SwiftData store boundary.
///
/// User-authored activity is synchronized through the existing `Tsumiben`
/// store. Rebuildable presentation indexes live in a separate local store so
/// a device can never publish its partially rebuilt aggregate graph through
/// CloudKit. Shipping URLs include an opaque, verified-account namespace; the
/// configuration names remain stable only for SwiftData entity routing.
@MainActor
enum PersistenceStoreTopology {
    static let cloudStoreName = "Tsumiben"
    static let localProjectionStoreName = "TsumibenLocalProjection"
    static let localOnlySourceStoreName = "TsumibenLocalOnly"
    static let localOnlyProjectionStoreName = "TsumibenLocalOnlyProjection"
    static let simulatorCloudStoreName = "TsumibenSimulator"
    static let simulatorLocalProjectionStoreName = "TsumibenSimulatorLocalProjection"

    static var shippingSchema: Schema {
        Schema(cloudModelTypes + localProjectionModelTypes)
    }

    static var cloudSchema: Schema {
        Schema(cloudModelTypes)
    }

    static var localProjectionSchema: Schema {
        Schema(localProjectionModelTypes)
    }

    /// URLs that contain user data in a shipping build. Complete-data deletion
    /// uses the values produced by `ModelConfiguration` rather than guessing a
    /// path in Application Support.
    static func shippingPersistentStoreURLs(
        accountNamespace: AccountDataNamespace
    ) -> [URL] {
        shippingConfigurations(accountNamespace: accountNamespace).map(\.url)
    }

    static func persistentStoreURLs(
        for mode: PersistenceLaunchMode,
        accountNamespace: AccountDataNamespace? = nil
    ) throws -> [URL] {
        switch mode {
        case .inMemoryPreview:
            return []
        case .persistentSimulator:
            return simulatorConfigurations.map(\.url)
        case .localOnly:
            guard let accountNamespace else {
                throw PersistenceStoreTopologyError.missingVerifiedAccountNamespace
            }
            return localOnlyPersistentStoreURLs(namespace: accountNamespace)
        case .cloudKit:
            guard let accountNamespace else {
                throw PersistenceStoreTopologyError.missingVerifiedAccountNamespace
            }
            return shippingPersistentStoreURLs(
                accountNamespace: accountNamespace
            )
        }
    }

    /// Exact application-owned persistence artifacts. Callers may derive the
    /// standard SQLite `-wal`/`-shm` siblings for each store URL. This list is
    /// intentionally limited to app data and the pre-split migration sidecar;
    /// it never includes a complete-deletion receipt or retry journal.
    static func deletionArtifactURLs(
        for mode: PersistenceLaunchMode,
        accountNamespace: AccountDataNamespace? = nil
    ) throws -> [URL] {
        let stores = try persistentStoreURLs(
            for: mode,
            accountNamespace: accountNamespace
        )
        guard let localStoreURL = stores.last else { return stores }
        let migrationIdentifier: String
        switch mode {
        case .inMemoryPreview:
            return []
        case .persistentSimulator:
            migrationIdentifier = "simulator-v1"
        case .localOnly:
            guard let accountNamespace else {
                throw PersistenceStoreTopologyError.missingVerifiedAccountNamespace
            }
            migrationIdentifier = "local-only-\(accountNamespace.rawValue)-v1"
        case .cloudKit:
            guard let accountNamespace else {
                throw PersistenceStoreTopologyError.missingVerifiedAccountNamespace
            }
            migrationIdentifier = "shipping-\(accountNamespace.rawValue)-v1"
        }
        return stores + [
            LocalProjectionStoreMigration.sidecarURL(
                localStoreURL: localStoreURL,
                identifier: migrationIdentifier
            ),
            LocalProjectionStoreMigration.stagingURL(
                localStoreURL: localStoreURL,
                identifier: migrationIdentifier
            )
        ]
    }

    static func makeContainer(
        for mode: PersistenceLaunchMode,
        accountNamespace: AccountDataNamespace? = nil
    ) throws -> ModelContainer {
        switch mode {
        case .inMemoryPreview:
            return try ModelContainer(
                for: shippingSchema,
                configurations: previewConfigurations
            )
        case .persistentSimulator:
            return try makePersistentContainer(
                configurations: simulatorConfigurations,
                legacyConfiguration: simulatorLegacyConfiguration,
                migrationIdentifier: "simulator-v1"
            )
        case .localOnly:
            guard let accountNamespace else {
                throw PersistenceStoreTopologyError.missingVerifiedAccountNamespace
            }
            return try ModelContainer(
                for: shippingSchema,
                configurations: localOnlyConfigurations(
                    namespace: accountNamespace
                )
            )
        case .cloudKit:
            guard let accountNamespace else {
                throw PersistenceStoreTopologyError.missingVerifiedAccountNamespace
            }
            let configurations = shippingConfigurations(
                accountNamespace: accountNamespace
            )
#if DEBUG
            // Development builds may still contain a monolithic local store
            // created while the split-store design was being exercised. Keep
            // that migration available to developers and to its focused tests.
            return try makePersistentContainer(
                configurations: configurations,
                legacyConfiguration: shippingLegacyConfiguration(
                    accountNamespace: accountNamespace
                ),
                migrationIdentifier: "shipping-\(accountNamespace.rawValue)-v1"
            )
#else
            // Version 1.0 has no previously distributed production build.
            // Opening the same SQLite URL first with the former all-model
            // CloudKit schema and then with the split schema is not a safe
            // first-launch migration. A shipping build therefore mounts the
            // final two-store topology directly. Any future public migration
            // must be versioned and validated against an actually released
            // store instead of reusing this development-only bridge.
            return try ModelContainer(
                for: shippingSchema,
                configurations: configurations
            )
#endif
        }
    }

#if DEBUG
    /// Test-only constructor with explicit temporary URLs. It exercises the
    /// same monolithic-to-split migration without touching application data or
    /// requiring CloudKit entitlements in the Simulator test host.
    static func makeTestingSplitContainer(
        cloudStoreURL: URL,
        localStoreURL: URL,
        defaults: UserDefaults,
        migrationIdentifier: String
    ) throws -> ModelContainer {
        let cloud = ModelConfiguration(
            "TsumibenTestingCloud",
            schema: cloudSchema,
            url: cloudStoreURL,
            cloudKitDatabase: .none
        )
        let local = ModelConfiguration(
            "TsumibenTestingLocalProjection",
            schema: localProjectionSchema,
            url: localStoreURL,
            cloudKitDatabase: .none
        )
        let legacy = ModelConfiguration(
            "TsumibenTestingLegacy",
            schema: shippingSchema,
            url: cloudStoreURL,
            cloudKitDatabase: .none
        )
        return try makePersistentContainer(
            configurations: [cloud, local],
            legacyConfiguration: legacy,
            migrationIdentifier: migrationIdentifier,
            defaults: defaults
        )
    }
#endif

    private static let cloudModelTypes: [any PersistentModel.Type] = [
        Subject.self,
        StudySession.self,
        AchievementStone.self,
        Prefs.self,
        ActivityResetMarker.self,
        SyncedFocusTimer.self,
        FocusTimerDeviceClaim.self
    ]

    private static let localProjectionModelTypes: [any PersistentModel.Type] = [
        AggregatePebble.self,
        Stratum.self,
        Bedrock.self,
        GachaState.self
    ]

    private static var previewConfigurations: [ModelConfiguration] {
        // SwiftData does not reliably route relationships when two ephemeral
        // configurations share its in-memory backing store. Preview data is
        // disposable and never reaches CloudKit, so one all-model memory
        // configuration preserves test/UI-preview behavior without weakening
        // the shipping disk boundary.
        [ModelConfiguration(
            "TsumibenPreview",
            schema: shippingSchema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )]
    }

    private static func shippingConfigurations(
        accountNamespace: AccountDataNamespace
    ) -> [ModelConfiguration] {
        let urls = accountStoreURLs(accountNamespace: accountNamespace)
        return [
            ModelConfiguration(
                cloudStoreName,
                schema: cloudSchema,
                url: urls[0],
                cloudKitDatabase: .private(
                    CloudSyncConfiguration.synchronizedDataContainerIdentifier
                )
            ),
            ModelConfiguration(
                localProjectionStoreName,
                schema: localProjectionSchema,
                url: urls[1],
                cloudKitDatabase: .none
            )
        ]
    }

    static func localOnlyConfigurations(
        namespace: AccountDataNamespace,
        directory: URL? = nil
    ) -> [ModelConfiguration] {
        let urls = localOnlyPersistentStoreURLs(
            namespace: namespace,
            directory: directory
        )
        return [
            ModelConfiguration(
                localOnlySourceStoreName,
                schema: cloudSchema,
                url: urls[0],
                cloudKitDatabase: .none
            ),
            ModelConfiguration(
                localOnlyProjectionStoreName,
                schema: localProjectionSchema,
                url: urls[1],
                cloudKitDatabase: .none
            )
        ]
    }

    static func localOnlyPersistentStoreURLs(
        namespace: AccountDataNamespace,
        directory: URL? = nil
    ) -> [URL] {
        let resolvedDirectory = directory ?? defaultStoreDirectory
        return [localOnlySourceStoreName, localOnlyProjectionStoreName].map {
            name in
            resolvedDirectory.appendingPathComponent(
                "\(name)-\(namespace.rawValue).store",
                isDirectory: false
            )
        }
    }

    /// Pure URL derivation used by launch policy tests. Both synchronized rows
    /// and their rebuildable local projections move together at account switch.
    static func accountStoreURLs(
        accountNamespace: AccountDataNamespace,
        directory: URL? = nil
    ) -> [URL] {
        let resolvedDirectory = directory ?? defaultStoreDirectory
        return [cloudStoreName, localProjectionStoreName].map { name in
            resolvedDirectory.appendingPathComponent(
                "\(name)-\(accountNamespace.rawValue).store",
                isDirectory: false
            )
        }
    }

    static func hasCloudStoreHistory(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        !persistenceArtifactHistory(
            directory: directory,
            fileManager: fileManager
        ).cloud.isEmpty
    }

    static func persistenceArtifactHistory(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> PersistenceArtifactHistory {
        let resolvedDirectory = directory ?? defaultStoreDirectory
        let resourceKeys: Set<URLResourceKey> = [
            .isSymbolicLinkKey,
            .isRegularFileKey,
            .isDirectoryKey
        ]
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: resolvedDirectory,
                includingPropertiesForKeys: Array(resourceKeys),
                options: []
            )
        } catch {
            guard fileManager.fileExists(atPath: resolvedDirectory.path) else {
                return PersistenceArtifactHistory()
            }
            return PersistenceArtifactHistory(hasInvalidArtifact: true)
        }

        var history = PersistenceArtifactHistory()
        for url in urls {
            let name = url.lastPathComponent
            guard isPersistenceArtifactCandidate(name) else { continue }
            guard let values = try? url.resourceValues(
                forKeys: resourceKeys
            ),
            values.isSymbolicLink != true
            else {
                history.hasInvalidArtifact = true
                continue
            }

            if let parsed = parseStoreArtifactName(name) {
                let hasExpectedType = parsed.expectsDirectory
                    ? values.isDirectory == true
                    : values.isRegularFile == true
                guard hasExpectedType else {
                    history.hasInvalidArtifact = true
                    continue
                }
                recordStoreArtifact(parsed, in: &history)
                continue
            }

            if let parsed = parseMigrationArtifactName(name) {
                guard values.isRegularFile == true else {
                    history.hasInvalidArtifact = true
                    continue
                }
                recordMigrationArtifact(parsed, in: &history)
                continue
            }

            history.hasInvalidArtifact = true
        }
        return history
    }

    private static var defaultStoreDirectory: URL {
        ModelConfiguration(
            cloudStoreName,
            schema: cloudSchema,
            cloudKitDatabase: .none
        ).url.deletingLastPathComponent()
    }

    private enum PersistedArtifactKind {
        case cloud
        case localOnly
    }

    private enum PersistedStoreRole {
        case source
        case projection
    }

    private struct ParsedStoreArtifact {
        let kind: PersistedArtifactKind
        let role: PersistedStoreRole
        let namespace: AccountDataNamespace
        let expectsDirectory: Bool
        let isPrimaryStore: Bool
    }

    private static func isPersistenceArtifactCandidate(
        _ name: String
    ) -> Bool {
        let legacyBases = [
            cloudStoreName,
            localProjectionStoreName,
            localOnlySourceStoreName,
            localOnlyProjectionStoreName
        ]
        let isLegacyOrUnnamespaced = legacyBases.contains { base in
            let storeName = "\(base).store"
            return name == storeName
                || name.hasPrefix("\(storeName)-")
                || name.hasPrefix("\(storeName)_")
                || name.hasPrefix("\(storeName).")
        }
        return isLegacyOrUnnamespaced
            || name.hasPrefix("\(cloudStoreName)-")
            || name.hasPrefix("\(localProjectionStoreName)-")
            || name.hasPrefix("\(localOnlySourceStoreName)-")
            || name.hasPrefix("\(localOnlyProjectionStoreName)-")
            || name.hasPrefix(".tumiben-local-projection-")
    }

    private static func parseStoreArtifactName(
        _ name: String
    ) -> ParsedStoreArtifact? {
        let bases: [(String, PersistedArtifactKind, PersistedStoreRole)] = [
            (localOnlyProjectionStoreName, .localOnly, .projection),
            (localOnlySourceStoreName, .localOnly, .source),
            (localProjectionStoreName, .cloud, .projection),
            (cloudStoreName, .cloud, .source)
        ]
        let suffixes: [(String, Bool, Bool)] = [
            (".store", false, true),
            (".store-wal", false, false),
            (".store-shm", false, false),
            (".store-journal", false, false),
            (".store_SUPPORT", true, false),
            (".store.ckAssetFiles", true, false)
        ]
        for (base, kind, role) in bases {
            let prefix = "\(base)-"
            guard name.hasPrefix(prefix) else { continue }
            for (suffix, expectsDirectory, isPrimaryStore) in suffixes
            where name.hasSuffix(suffix) {
                let start = name.index(
                    name.startIndex,
                    offsetBy: prefix.count
                )
                let end = name.index(
                    name.endIndex,
                    offsetBy: -suffix.count
                )
                guard start < end,
                      let namespace = AccountDataNamespace(
                        rawValue: String(name[start..<end])
                      ),
                      String(name[start..<end]) == namespace.rawValue
                else { return nil }
                return ParsedStoreArtifact(
                    kind: kind,
                    role: role,
                    namespace: namespace,
                    expectsDirectory: expectsDirectory,
                    isPrimaryStore: isPrimaryStore
                )
            }
            return nil
        }
        return nil
    }

    private static func parseMigrationArtifactName(
        _ name: String
    ) -> (kind: PersistedArtifactKind, namespace: AccountDataNamespace)? {
        let prefix = ".tumiben-local-projection-"
        guard name.hasPrefix(prefix) else { return nil }
        let variants: [(String, PersistedArtifactKind)] = [
            ("shipping-", .cloud),
            ("local-only-", .localOnly)
        ]
        let suffixes = ["-v1.json", "-v1.staging.json"]
        let remainder = String(name.dropFirst(prefix.count))
        for (variant, kind) in variants where remainder.hasPrefix(variant) {
            for suffix in suffixes where remainder.hasSuffix(suffix) {
                let raw = remainder
                    .dropFirst(variant.count)
                    .dropLast(suffix.count)
                guard let namespace = AccountDataNamespace(
                    rawValue: String(raw)
                ), String(raw) == namespace.rawValue else { return nil }
                return (kind, namespace)
            }
            return nil
        }
        return nil
    }

    private static func recordStoreArtifact(
        _ parsed: ParsedStoreArtifact,
        in history: inout PersistenceArtifactHistory
    ) {
        var artifacts: PersistenceArtifactHistory.NamespaceArtifacts
        switch parsed.kind {
        case .cloud:
            artifacts = history.cloud[parsed.namespace, default: .init()]
        case .localOnly:
            artifacts = history.localOnly[parsed.namespace, default: .init()]
        }
        if parsed.isPrimaryStore {
            switch parsed.role {
            case .source:
                artifacts.hasSourceStore = true
            case .projection:
                artifacts.hasProjectionStore = true
            }
        } else {
            artifacts.hasAuxiliaryArtifact = true
        }
        switch parsed.kind {
        case .cloud:
            history.cloud[parsed.namespace] = artifacts
        case .localOnly:
            history.localOnly[parsed.namespace] = artifacts
        }
    }

    private static func recordMigrationArtifact(
        _ parsed: (kind: PersistedArtifactKind, namespace: AccountDataNamespace),
        in history: inout PersistenceArtifactHistory
    ) {
        switch parsed.kind {
        case .cloud:
            var artifacts = history.cloud[
                parsed.namespace,
                default: .init()
            ]
            artifacts.hasMigrationSidecar = true
            history.cloud[parsed.namespace] = artifacts
        case .localOnly:
            var artifacts = history.localOnly[
                parsed.namespace,
                default: .init()
            ]
            artifacts.hasMigrationSidecar = true
            history.localOnly[parsed.namespace] = artifacts
        }
    }

    private static var simulatorConfigurations: [ModelConfiguration] {
        [
            ModelConfiguration(
                simulatorCloudStoreName,
                schema: cloudSchema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            ),
            ModelConfiguration(
                simulatorLocalProjectionStoreName,
                schema: localProjectionSchema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
        ]
    }

    private static func shippingLegacyConfiguration(
        accountNamespace: AccountDataNamespace
    ) -> ModelConfiguration {
        ModelConfiguration(
            cloudStoreName,
            schema: shippingSchema,
            url: accountStoreURLs(accountNamespace: accountNamespace)[0],
            cloudKitDatabase: .private(
                CloudSyncConfiguration.synchronizedDataContainerIdentifier
            )
        )
    }

    private static var simulatorLegacyConfiguration: ModelConfiguration {
        ModelConfiguration(
            simulatorCloudStoreName,
            schema: shippingSchema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
    }

    private static func makePersistentContainer(
        configurations: [ModelConfiguration],
        legacyConfiguration: ModelConfiguration,
        migrationIdentifier: String,
        defaults: UserDefaults = .standard
    ) throws -> ModelContainer {
        guard configurations.count == 2 else {
            throw PersistenceStoreTopologyError.invalidConfiguration
        }
        let cloudURL = configurations[0].url
        let localURL = configurations[1].url
        let migration = LocalProjectionStoreMigration(
            legacyConfiguration: legacyConfiguration,
            cloudStoreURL: cloudURL,
            localStoreURL: localURL,
            identifier: migrationIdentifier,
            defaults: defaults
        )
        let snapshot = try migration.prepareIfNeeded()
        let container = try ModelContainer(
            for: shippingSchema,
            configurations: configurations
        )
        try migration.finishIfNeeded(snapshot: snapshot, in: container)
        return container
    }
}

enum PersistenceStoreTopologyError: LocalizedError {
    case invalidConfiguration
    case unsafeLegacyProjectionMigration
    case missingVerifiedAccountNamespace
    case incompleteStorePairAfterMount

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "保存領域の構成が不正です。"
        case .unsafeLegacyProjectionMigration:
            "保存領域を安全に移行できませんでした。"
        case .missingVerifiedAccountNamespace:
            "Apple Accountを確認できるまで保存領域を開けません。"
        case .incompleteStorePairAfterMount:
            "保存領域の作成が完了していません。既存ファイルを削除せず停止しました。"
        }
    }
}

/// One-time, crash-resumable copy of rebuildable entities out of the former
/// all-model CloudKit store. The source is never deleted here. A durable
/// sidecar is written before the split store is opened, then imported
/// idempotently and removed only after the local store save succeeds.
@MainActor
private struct LocalProjectionStoreMigration {
    private static let formatVersion = 1

    let legacyConfiguration: ModelConfiguration
    let cloudStoreURL: URL
    let localStoreURL: URL
    let identifier: String
    let defaults: UserDefaults

    private var markerKey: String {
        "persistence.local-projection-split.\(identifier).complete"
    }

    private var sidecarURL: URL {
        Self.sidecarURL(localStoreURL: localStoreURL, identifier: identifier)
    }

    private var stagingURL: URL {
        Self.stagingURL(localStoreURL: localStoreURL, identifier: identifier)
    }

    static func sidecarURL(localStoreURL: URL, identifier: String) -> URL {
        localStoreURL.deletingLastPathComponent()
            .appendingPathComponent(".tumiben-local-projection-\(identifier).json")
    }

    static func stagingURL(localStoreURL: URL, identifier: String) -> URL {
        localStoreURL.deletingLastPathComponent()
            .appendingPathComponent(".tumiben-local-projection-\(identifier).staging.json")
    }

    func prepareIfNeeded() throws -> LocalProjectionSnapshot? {
        guard !defaults.bool(forKey: markerKey) else { return nil }

        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            return try decodeSidecar()
        }

        // A crash while writing the deterministic staging file cannot make a
        // partial JSON document look committed. The source store is untouched,
        // so discarding and recreating this exact artifact is safe.
        if FileManager.default.fileExists(atPath: stagingURL.path) {
            try FileManager.default.removeItem(at: stagingURL)
        }

        // A local store without a pending sidecar means a prior split launch
        // already crossed the physical boundary. Never reopen the cloud store
        // with the legacy full schema in that state.
        if FileManager.default.fileExists(atPath: localStoreURL.path) {
            defaults.set(true, forKey: markerKey)
            return nil
        }

        guard FileManager.default.fileExists(atPath: cloudStoreURL.path) else {
            // Fresh install: there is no old projection to preserve.
            return LocalProjectionSnapshot.empty
        }

        let snapshot = try readLegacyProjection()
        try writeSidecar(snapshot)
        return snapshot
    }

    func finishIfNeeded(
        snapshot preparedSnapshot: LocalProjectionSnapshot?,
        in container: ModelContainer
    ) throws {
        guard !defaults.bool(forKey: markerKey) else { return }

        let snapshot: LocalProjectionSnapshot
        if let preparedSnapshot {
            snapshot = preparedSnapshot
        } else if FileManager.default.fileExists(atPath: sidecarURL.path) {
            snapshot = try decodeSidecar()
        } else {
            throw PersistenceStoreTopologyError.unsafeLegacyProjectionMigration
        }

        try snapshot.insertMissingRows(into: container.mainContext)
        defaults.set(true, forKey: markerKey)
        try? FileManager.default.removeItem(at: sidecarURL)
        try? FileManager.default.removeItem(at: stagingURL)
    }

    private func readLegacyProjection() throws -> LocalProjectionSnapshot {
        let legacyContainer = try ModelContainer(
            for: PersistenceStoreTopology.shippingSchema,
            configurations: [legacyConfiguration]
        )
        return try LocalProjectionSnapshot(context: legacyContainer.mainContext)
    }

    private func writeSidecar(_ snapshot: LocalProjectionSnapshot) throws {
        let directory = sidecarURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: stagingURL)
#if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: stagingURL.path
        )
#endif
        // Rename within one directory is the commit point. Unlike
        // Data.WritingOptions.atomic this never leaves a randomly named file
        // that complete-data deletion cannot enumerate exactly.
        try FileManager.default.moveItem(at: stagingURL, to: sidecarURL)
    }

    private func decodeSidecar() throws -> LocalProjectionSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(
            LocalProjectionSnapshot.self,
            from: Data(contentsOf: sidecarURL)
        )
        guard snapshot.formatVersion == Self.formatVersion else {
            throw PersistenceStoreTopologyError.unsafeLegacyProjectionMigration
        }
        return snapshot
    }
}

private struct LocalProjectionSnapshot: Codable {
    let formatVersion: Int
    let aggregates: [Aggregate]
    let strata: [LegacyStratum]
    let bedrocks: [LegacyBedrock]
    let gachaStates: [Gacha]

    static let empty = Self(
        formatVersion: 1,
        aggregates: [],
        strata: [],
        bedrocks: [],
        gachaStates: []
    )

    @MainActor
    init(context: ModelContext) throws {
        formatVersion = 1
        aggregates = try context.fetch(FetchDescriptor<AggregatePebble>()).map(Aggregate.init)
        strata = try context.fetch(FetchDescriptor<Stratum>()).map(LegacyStratum.init)
        bedrocks = try context.fetch(FetchDescriptor<Bedrock>()).map(LegacyBedrock.init)
        gachaStates = try context.fetch(FetchDescriptor<GachaState>()).map(Gacha.init)
    }

    private init(
        formatVersion: Int,
        aggregates: [Aggregate],
        strata: [LegacyStratum],
        bedrocks: [LegacyBedrock],
        gachaStates: [Gacha]
    ) {
        self.formatVersion = formatVersion
        self.aggregates = aggregates
        self.strata = strata
        self.bedrocks = bedrocks
        self.gachaStates = gachaStates
    }

    @MainActor
    func insertMissingRows(into context: ModelContext) throws {
        let aggregateIDs = Set(try context.fetch(FetchDescriptor<AggregatePebble>()).map(\.id))
        for value in aggregates where !aggregateIDs.contains(value.id) {
            context.insert(value.makeModel())
        }

        let stratumIDs = Set(try context.fetch(FetchDescriptor<Stratum>()).map(\.id))
        for value in strata where !stratumIDs.contains(value.id) {
            context.insert(value.makeModel())
        }

        let bedrockKeys = Set(try context.fetch(FetchDescriptor<Bedrock>()).map(LegacyBedrock.key))
        for value in bedrocks where !bedrockKeys.contains(value.key) {
            context.insert(value.makeModel())
        }

        let gachaIDs = Set(try context.fetch(FetchDescriptor<GachaState>()).map(\.id))
        for value in gachaStates where !gachaIDs.contains(value.id) {
            context.insert(value.makeModel())
        }
        if context.hasChanges { try context.save() }
    }

    struct Aggregate: Codable {
        let id: UUID
        let dataEpochID: UUID?
        let createdAt: Date
        let level: Int
        let pebbleCount: Int
        let childAggregateCount: Int
        let grams: Int
        let measuredPebbleCount: Int
        let manualPebbleCount: Int
        let goldPebbleCount: Int
        let prismPebbleCount: Int
        let colorMixJSON: String
        let subjectMixJSON: String
        let periodStart: Date
        let periodEnd: Date
        let sessionIDs: [UUID]
        let childAggregateIDs: [UUID]
        let parentAggregateID: UUID?

        init(_ value: AggregatePebble) {
            id = value.id
            dataEpochID = value.dataEpochID
            createdAt = value.createdAt
            level = value.level
            pebbleCount = value.pebbleCount
            childAggregateCount = value.childAggregateCount
            grams = value.grams
            measuredPebbleCount = value.measuredPebbleCount
            manualPebbleCount = value.manualPebbleCount
            goldPebbleCount = value.goldPebbleCount
            prismPebbleCount = value.prismPebbleCount
            colorMixJSON = value.colorMixJSON
            subjectMixJSON = value.subjectMixJSON
            periodStart = value.periodStart
            periodEnd = value.periodEnd
            sessionIDs = value.sessionIDs
            childAggregateIDs = value.childAggregateIDs
            parentAggregateID = value.parentAggregateID
        }

        func makeModel() -> AggregatePebble {
            AggregatePebble(
                id: id,
                createdAt: createdAt,
                level: level,
                pebbleCount: pebbleCount,
                childAggregateCount: childAggregateCount,
                grams: grams,
                measuredPebbleCount: measuredPebbleCount,
                manualPebbleCount: manualPebbleCount,
                goldPebbleCount: goldPebbleCount,
                prismPebbleCount: prismPebbleCount,
                colorMixJSON: colorMixJSON,
                subjectMixJSON: subjectMixJSON,
                periodStart: periodStart,
                periodEnd: periodEnd,
                sessionIDs: sessionIDs,
                childAggregateIDs: childAggregateIDs,
                parentAggregateID: parentAggregateID,
                dataEpochID: dataEpochID,
                // The legacy monolithic schema predates logical-session
                // validation. The maintenance verifier must prove this cached
                // projection before Home can treat it as exact.
                projectionValidationVersion: 0
            )
        }
    }

    struct LegacyStratum: Codable {
        let id: UUID
        let dataEpochID: UUID?
        let bakedAt: Date
        let pebbleCount: Int
        let heightPt: Double
        let colorMixJSON: String
        let monthLabel: String
        let grams: Int
        let sessionIDs: [UUID]

        init(_ value: Stratum) {
            id = value.id
            dataEpochID = value.dataEpochID
            bakedAt = value.bakedAt
            pebbleCount = value.pebbleCount
            heightPt = value.heightPt
            colorMixJSON = value.colorMixJSON
            monthLabel = value.monthLabel
            grams = value.grams
            sessionIDs = value.sessionIDs
        }

        func makeModel() -> Stratum {
            Stratum(
                id: id,
                bakedAt: bakedAt,
                pebbleCount: pebbleCount,
                heightPt: heightPt,
                colorMixJSON: colorMixJSON,
                monthLabel: monthLabel,
                grams: grams,
                sessionIDs: sessionIDs,
                dataEpochID: dataEpochID
            )
        }
    }

    struct LegacyBedrock: Codable {
        let dataEpochID: UUID?
        let hours: Int
        let importedAt: Date

        init(_ value: Bedrock) {
            dataEpochID = value.dataEpochID
            hours = value.hours
            importedAt = value.importedAt
        }

        var key: String {
            "\(dataEpochID?.uuidString ?? "legacy")|\(hours)|\(importedAt.timeIntervalSinceReferenceDate)"
        }

        static func key(_ value: Bedrock) -> String {
            Self(value).key
        }

        func makeModel() -> Bedrock {
            Bedrock(hours: hours, importedAt: importedAt, dataEpochID: dataEpochID)
        }
    }

    struct Gacha: Codable {
        let id: UUID
        let dataEpochID: UUID?
        let sinceLastGold: Int
        let rewardCreditGrams: Int

        init(_ value: GachaState) {
            id = value.id
            dataEpochID = value.dataEpochID
            sinceLastGold = value.sinceLastGold
            rewardCreditGrams = value.rewardCreditGrams
        }

        func makeModel() -> GachaState {
            GachaState(
                id: id,
                sinceLastGold: sinceLastGold,
                rewardCreditGrams: rewardCreditGrams,
                dataEpochID: dataEpochID
            )
        }
    }
}
