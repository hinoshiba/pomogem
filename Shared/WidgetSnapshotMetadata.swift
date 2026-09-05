import Foundation

/// Opaque, random on-device name for one verified Apple Account. The CloudKit
/// user record name is deliberately never used in a file name or defaults key.
struct AccountDataNamespace: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    init() {
        rawValue = UUID().uuidString.lowercased()
    }

    init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.rawValue = uuid.uuidString.lowercased()
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try values.decode(String.self, forKey: .rawValue)
        guard let validated = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .rawValue,
                in: values,
                debugDescription: "Account namespace must be a UUID."
            )
        }
        self = validated
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(rawValue, forKey: .rawValue)
    }
}

/// Validator for the SHA-256 digest derived from CloudKit's current-user record
/// identifier. The unhashed CloudKit identifier is never persisted locally.
enum AppleAccountFingerprint {
    static func isValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

/// Persisted proof that the app resolved this local namespace from a currently
/// available CloudKit account. Shipping launches clear this binding before
/// re-verifying the account online, so possession of the persisted digest alone
/// never authorizes a store mount.
struct ActiveAccountLocalBinding: Codable, Equatable, Sendable {
    let namespace: AccountDataNamespace
    let accountFingerprint: String

    private enum CodingKeys: String, CodingKey {
        case namespace
        case accountFingerprint
    }

    init?(namespace: AccountDataNamespace, accountFingerprint: String) {
        guard AppleAccountFingerprint.isValid(accountFingerprint) else {
            return nil
        }
        self.namespace = namespace
        self.accountFingerprint = accountFingerprint
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let namespace = try values.decode(
            AccountDataNamespace.self,
            forKey: .namespace
        )
        let accountFingerprint = try values.decode(
            String.self,
            forKey: .accountFingerprint
        )
        guard let validated = Self(
            namespace: namespace,
            accountFingerprint: accountFingerprint
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .accountFingerprint,
                in: values,
                debugDescription: "Apple Account fingerprint must be a lowercase SHA-256 digest."
            )
        }
        self = validated
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(namespace, forKey: .namespace)
        try values.encode(accountFingerprint, forKey: .accountFingerprint)
    }
}

/// Account scope for local recovery state. A cloud launch sets the boundary
/// before any ModelContainer exists. Optional secondary defaults remain only as
/// an injection seam for migration tests; the version 1 app has no App Group.
enum AccountScopedLocalState {
    private static let cloudBoundaryRequiredKey =
        "account-boundary.cloud-scope-required.v1"
    private static let activeBindingKey =
        "account-boundary.active-binding.v1"
    private static let activeLocalOnlyNamespaceKey =
        "persistence.active-local-only-namespace.v1"
    private static let pendingPreviousBindingKey =
        "account-boundary.pending-previous-binding.v1"
    private static let inactiveKeyPrefix =
        "account-boundary.inactive"

    static func beginCloudBoundary(
        standardDefaults: UserDefaults = .standard,
        appGroupDefaults: UserDefaults? = nil
    ) {
        if let activeData = standardDefaults.data(forKey: activeBindingKey) {
            // Preserve the last verified binding while the store is unmounted.
            // A cold launch after an account switch can then retire pending
            // notifications and Live Activities before exposing a new account.
            standardDefaults.set(activeData, forKey: pendingPreviousBindingKey)
        }
        standardDefaults.set(true, forKey: cloudBoundaryRequiredKey)
        standardDefaults.removeObject(forKey: activeBindingKey)
        standardDefaults.removeObject(forKey: activeLocalOnlyNamespaceKey)
        appGroupDefaults?.set(true, forKey: cloudBoundaryRequiredKey)
        appGroupDefaults?.removeObject(forKey: activeBindingKey)
        appGroupDefaults?.removeObject(forKey: activeLocalOnlyNamespaceKey)
    }

    static func useUnscopedLocalMode(
        standardDefaults: UserDefaults = .standard,
        appGroupDefaults: UserDefaults? = nil
    ) {
        standardDefaults.set(false, forKey: cloudBoundaryRequiredKey)
        standardDefaults.removeObject(forKey: activeBindingKey)
        standardDefaults.removeObject(forKey: activeLocalOnlyNamespaceKey)
        standardDefaults.removeObject(forKey: pendingPreviousBindingKey)
        appGroupDefaults?.set(false, forKey: cloudBoundaryRequiredKey)
        appGroupDefaults?.removeObject(forKey: activeBindingKey)
        appGroupDefaults?.removeObject(forKey: activeLocalOnlyNamespaceKey)
    }

    static func activate(
        _ binding: ActiveAccountLocalBinding,
        standardDefaults: UserDefaults = .standard,
        appGroupDefaults: UserDefaults? = nil
    ) throws {
        let data = try JSONEncoder().encode(binding)
        standardDefaults.set(true, forKey: cloudBoundaryRequiredKey)
        standardDefaults.set(data, forKey: activeBindingKey)
        standardDefaults.removeObject(forKey: activeLocalOnlyNamespaceKey)
        appGroupDefaults?.set(true, forKey: cloudBoundaryRequiredKey)
        appGroupDefaults?.set(data, forKey: activeBindingKey)
        appGroupDefaults?.removeObject(forKey: activeLocalOnlyNamespaceKey)
    }

    static func activateLocalOnly(
        namespace: AccountDataNamespace,
        standardDefaults: UserDefaults = .standard,
        appGroupDefaults: UserDefaults? = nil
    ) {
        standardDefaults.set(true, forKey: cloudBoundaryRequiredKey)
        standardDefaults.removeObject(forKey: activeBindingKey)
        standardDefaults.removeObject(forKey: pendingPreviousBindingKey)
        standardDefaults.set(
            namespace.rawValue,
            forKey: activeLocalOnlyNamespaceKey
        )
        appGroupDefaults?.set(true, forKey: cloudBoundaryRequiredKey)
        appGroupDefaults?.removeObject(forKey: activeBindingKey)
        appGroupDefaults?.set(
            namespace.rawValue,
            forKey: activeLocalOnlyNamespaceKey
        )
    }

    static func deactivate(
        standardDefaults: UserDefaults = .standard,
        appGroupDefaults: UserDefaults? = nil
    ) {
        standardDefaults.removeObject(forKey: activeBindingKey)
        standardDefaults.removeObject(forKey: activeLocalOnlyNamespaceKey)
        appGroupDefaults?.removeObject(forKey: activeBindingKey)
        appGroupDefaults?.removeObject(forKey: activeLocalOnlyNamespaceKey)
    }

    static func activeBinding(
        defaults: UserDefaults = .standard
    ) -> ActiveAccountLocalBinding? {
        guard let data = defaults.data(forKey: activeBindingKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ActiveAccountLocalBinding.self, from: data)
    }

    static func pendingPreviousBinding(
        defaults: UserDefaults = .standard
    ) -> ActiveAccountLocalBinding? {
        guard let data = defaults.data(forKey: pendingPreviousBindingKey) else {
            return nil
        }
        return try? JSONDecoder().decode(ActiveAccountLocalBinding.self, from: data)
    }

    static func clearPendingPreviousBinding(
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: pendingPreviousBindingKey)
    }

    static func activeNamespace(
        defaults: UserDefaults = .standard
    ) -> AccountDataNamespace? {
        if let namespace = activeBinding(defaults: defaults)?.namespace {
            return namespace
        }
        guard defaults.bool(forKey: cloudBoundaryRequiredKey),
              let rawValue = defaults.string(
                forKey: activeLocalOnlyNamespaceKey
              )
        else { return nil }
        return AccountDataNamespace(rawValue: rawValue)
    }

    static func hasPersistedCloudBindingHistory(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.data(forKey: activeBindingKey) != nil
            || defaults.data(forKey: pendingPreviousBindingKey) != nil
    }

    /// Version 1 widgets are deliberately account-neutral and never resolve an
    /// app account binding. This remains fail-closed even in local debug mode.
    static func verifiedWidgetBinding(
        defaults: UserDefaults? = nil
    ) -> ActiveAccountLocalBinding? {
        nil
    }

    static func defaultsKey(
        base: String,
        defaults: UserDefaults = .standard
    ) -> String {
        if let namespace = activeNamespace(defaults: defaults) {
            return defaultsKey(base: base, namespace: namespace)
        }
        guard defaults.bool(forKey: cloudBoundaryRequiredKey) else {
            return base
        }
        return "\(inactiveKeyPrefix).\(base)"
    }

    static func defaultsKey(
        base: String,
        namespace: AccountDataNamespace
    ) -> String {
        "\(base).account.\(namespace.rawValue)"
    }

    static func keyBelongsToActiveNamespace(
        _ key: String,
        basePrefix: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard key.hasPrefix(basePrefix) else { return false }
        if let namespace = activeNamespace(defaults: defaults) {
            return key.hasSuffix(".account.\(namespace.rawValue)")
        }
        // Explicit local preview/simulator mode retains legacy unscoped keys.
        return !defaults.bool(forKey: cloudBoundaryRequiredKey)
            && !key.contains(".account.")
    }

    static func fileName(
        base: String,
        namespace: AccountDataNamespace
    ) -> String {
        "\(namespace.rawValue)-\(base)"
    }

    /// Version 1 never resolves a personalized widget artifact name.
    static func verifiedWidgetFileName(
        base: String,
        defaults: UserDefaults? = nil
    ) -> String? {
        nil
    }
}

/// Lightweight state persisted beside the rendered jar PNG in the App Group.
/// WidgetKit deliberately does not read SwiftData, which keeps widget launches
/// fast and makes a missing/iCloud-unavailable model container harmless.
struct WidgetSnapshotMetadata: Codable, Hashable, Sendable {
    static let currentVersion = 1

    var version: Int
    var totalGrams: Int
    var measuredGrams: Int
    var pebbleCount: Int
    var goldCount: Int
    var prismCount: Int
    var updatedAt: Date
    var imageFileName: String

    init(
        totalGrams: Int,
        measuredGrams: Int,
        pebbleCount: Int,
        goldCount: Int,
        prismCount: Int,
        updatedAt: Date = .now,
        imageFileName: String = IntegrationConstants.widgetSnapshotImageFileName
    ) {
        version = Self.currentVersion
        self.totalGrams = max(0, totalGrams)
        self.measuredGrams = max(0, measuredGrams)
        self.pebbleCount = max(0, pebbleCount)
        self.goldCount = max(0, goldCount)
        self.prismCount = max(0, prismCount)
        self.updatedAt = updatedAt
        self.imageFileName = imageFileName
    }

    static let empty = Self(
        totalGrams: 0,
        measuredGrams: 0,
        pebbleCount: 0,
        goldCount: 0,
        prismCount: 0
    )

    var formattedTotalMass: String {
        Self.format(grams: totalGrams)
    }

    var formattedMeasuredMass: String {
        Self.format(grams: measuredGrams)
    }

    private static func format(grams: Int) -> String {
        guard grams >= 1_000 else { return "\(grams)g" }

        let kilograms = Double(grams) / 1_000
        if grams.isMultiple(of: 1_000) {
            return "\(grams / 1_000)kg"
        }

        let formatted = String(format: "%.2f", kilograms)
            .replacingOccurrences(of: "0$", with: "", options: .regularExpression)
        return "\(formatted)kg"
    }
}
