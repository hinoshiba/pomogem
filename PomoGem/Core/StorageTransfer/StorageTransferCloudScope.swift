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
enum StorageTransferCloudEnvironment: String, Codable, Equatable, Sendable {
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
}
