import Foundation

/// Which CloudKit container environment a build actually talks to.
///
/// The app had no runtime concept of this at all: the environment is chosen
/// entirely by the signed `com.apple.developer.icloud-container-environment`
/// entitlement, which `project.yml` fills from the build configuration
/// (Debug -> Development, Release -> Production). Device-side transfer state
/// lives in the app container, which is keyed by bundle id only, so a
/// Development build and a Production build of the same bundle id shared one
/// admission receipt while reading two completely unrelated databases.
enum StorageTransferCloudEnvironment: String, CaseIterable, Codable, Equatable, Sendable {
    case development = "Development"
    case production = "Production"
    /// A receipt written before receipts recorded their environment, or a host
    /// whose entitlement could not be read. Never asserted to DIFFER from a
    /// known environment: absence of evidence is not evidence of difference.
    case unknown = "Unknown"
}

/// The identity of the database a dataset generation belongs to. A generation
/// UUID only means something inside one container/environment pair.
struct StorageTransferCloudScope: Codable, Equatable, Sendable {
    let environment: StorageTransferCloudEnvironment
    let containerIdentifier: String

    init(environment: StorageTransferCloudEnvironment, containerIdentifier: String) {
        self.environment = environment
        self.containerIdentifier = containerIdentifier
    }

    /// What an unscoped legacy receipt is worth: nothing is claimed about it.
    static let unknown = Self(environment: .unknown, containerIdentifier: "")

    var isKnown: Bool { environment != .unknown && !containerIdentifier.isEmpty }

    /// True only when BOTH sides are known and they differ. An unknown side
    /// never accuses a known one, so upgrading from a build that did not
    /// record the environment can never be reported as an environment change.
    func isProvenDifferent(from other: Self) -> Bool {
        guard isKnown, other.isKnown else { return false }
        return self != other
    }

    /// The file-name component. Only the environment appears: the container
    /// identifier is a compile-time constant with exactly one value, and the
    /// stored record carries it, so a future container change is still
    /// detected by `isProvenDifferent` rather than by silently missing a file.
    var fileNameComponent: String? {
        switch environment {
        case .development: "development"
        case .production: "production"
        case .unknown: nil
        }
    }
}

extension StorageTransferCloudScope {
    /// `PomoGem.entitlements` fills
    /// `com.apple.developer.icloud-container-environment` from the build
    /// setting `ICLOUD_CONTAINER_ENVIRONMENT` (project.yml: Debug ->
    /// Development, Release -> Production). `SecTask*` is not in the public
    /// iOS SDK, so the signed entitlement cannot be read back at runtime.
    /// Instead the SAME build setting is expanded into Info.plist under this
    /// key, which keeps one source of truth in project.yml rather than a
    /// second mapping that can drift away from the signed value.
    static let infoDictionaryKey = "POMOGEM_ICLOUD_CONTAINER_ENVIRONMENT"

    /// The mapping of last resort, used only when the entitlement cannot be
    /// read or is unrecognised. It mirrors `project.yml:79-86`.
    static var buildConfigurationEnvironment: StorageTransferCloudEnvironment {
        #if DEBUG
        .development
        #else
        .production
        #endif
    }

    /// CloudKit accepts the key as a string; some toolchains hand it back as a
    /// single-element array. Anything else is not evidence of an environment.
    static func environment(fromEntitlement value: Any?) -> StorageTransferCloudEnvironment {
        let text: String?
        switch value {
        case let string as String: text = string
        case let array as [String]: text = array.count == 1 ? array[0] : nil
        default: text = nil
        }
        guard let text, let parsed = StorageTransferCloudEnvironment(rawValue: text),
              parsed != .unknown else { return buildConfigurationEnvironment }
        return parsed
    }

    static func declaredEnvironmentValue(bundle: Bundle = .main,
                                         key: String = infoDictionaryKey) -> Any? {
        bundle.object(forInfoDictionaryKey: key)
    }

    static func resolved(entitlement: Any?,
                         containerIdentifier: String = CloudSyncConfiguration
                             .synchronizedDataContainerIdentifier) -> Self {
        Self(environment: environment(fromEntitlement: entitlement),
             containerIdentifier: containerIdentifier)
    }

    /// The scope of the running process. Resolved once: the build setting
    /// cannot change while the process lives.
    static func current() -> Self { resolvedForThisProcess }
    private static let resolvedForThisProcess = resolved(entitlement: declaredEnvironmentValue())
}
