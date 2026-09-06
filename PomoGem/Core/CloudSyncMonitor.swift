import CloudKit
import CryptoKit
import Observation
import SwiftUI
import UIKit

enum CloudSyncConfiguration {
    /// SwiftData/Core Data exclusively owns this container and its generated
    /// schema. Never create or mutate raw `CKRecord` types in it.
    static let synchronizedDataContainerIdentifier =
        "iCloud.com.hinoshiba.pomogem"

    /// Direct CloudKit records that require compare-and-swap semantics live in
    /// a separate container. Keeping this schema away from SwiftData follows
    /// Core Data's requirement that its mirroring container remain framework-
    /// managed, and also lets complete deletion address each store explicitly.
    static let operationsContainerIdentifier =
        "iCloud.com.hinoshiba.pomogem.operations"
}

enum CloudKitOnlineAccountVerifier {
    static let requestTimeout: TimeInterval = 6
    static let resourceTimeout: TimeInterval = 8

    static func makePrivateDatabaseProbe() -> CKFetchRecordZonesOperation {
        let operation = CKFetchRecordZonesOperation
            .fetchAllRecordZonesOperation()
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = .userInitiated
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        operation.configuration = configuration
        return operation
    }

    /// `accountStatus` and `userRecordID` may be satisfied from local account
    /// state. Fetching the private database's zones is a read-only CloudKit
    /// request whose documented failure cases include unavailable networking
    /// and a missing active iCloud account. Requiring it keeps the storage
    /// mount fail-closed without writing raw records into SwiftData's
    /// framework-managed container. Explicit request/resource deadlines keep
    /// launch on an actionable error screen instead of an indefinite spinner.
    static func verifyFreshPrivateDatabaseAccess(
        in container: CKContainer
    ) async throws {
        let database = container.privateCloudDatabase
        let operation = makePrivateDatabaseProbe()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.fetchRecordZonesResultBlock = { result in
                    continuation.resume(with: result)
                }
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
    }
}

struct ResolvedAppleAccountBoundary: Equatable, Sendable {
    let binding: ActiveAccountLocalBinding
}

enum AppleAccountBoundaryResolutionError: LocalizedError, Equatable {
    case blocked(AppleAccountBoundaryBlockReason)

    var errorDescription: String? {
        switch self {
        case .blocked(.identityUnavailable):
            "Apple AccountとiCloudをオンラインで確認できません。サインインと通信状態を確認できるまで記録の保存領域は開きません。"
        case .blocked(.accountMismatch):
            "このインストールでiCloud保存を選んだApple Accountと一致しません。元のApple Accountへ戻すまで保存領域は開きません。"
        case .blocked(.invalidVerifiedIdentity):
            "Apple Accountの識別情報を安全に確認できませんでした。"
        case .blocked(.invalidStoredRegistry):
            "端末内のApple Account対応情報を安全に検証できません。記録を保護するため保存領域は開きません。"
        }
    }
}

/// Resolves the account boundary before SwiftData is allowed to construct its
/// CloudKit-backed container. The immutable deployment profile contains only a
/// SHA-256 account fingerprint and a random local namespace. A legacy registry,
/// when present, is validated but resolution itself is side-effect free so a
/// late verification result cannot mutate a local-only choice. Every shipping
/// mount requires successful `accountStatus` and `userRecordID` lookups plus a
/// read-only private-database zone fetch; a cached local binding never
/// authorizes offline reuse.
@MainActor
struct AppleAccountBoundaryResolver {
    private static let registryDefaultsKey =
        "account-boundary.namespace-registry.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func hasPersistedRegistryHistory(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.data(forKey: registryDefaultsKey) != nil
    }

    func resolve(
        expectedBinding: ActiveAccountLocalBinding? = nil
    ) async throws -> ResolvedAppleAccountBoundary {
        let containerIdentifier = CloudSyncConfiguration
            .synchronizedDataContainerIdentifier
        let container = CKContainer(identifier: containerIdentifier)
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            try Task.checkCancellation()
            throw AppleAccountBoundaryResolutionError.blocked(
                .identityUnavailable
            )
        }
        try Task.checkCancellation()
        guard status == .available else {
            throw AppleAccountBoundaryResolutionError.blocked(
                .identityUnavailable
            )
        }

        let recordIDBeforeProbe: CKRecord.ID
        do {
            recordIDBeforeProbe = try await container.userRecordID()
        } catch {
            try Task.checkCancellation()
            throw AppleAccountBoundaryResolutionError.blocked(
                .identityUnavailable
            )
        }
        try Task.checkCancellation()
        do {
            try await CloudKitOnlineAccountVerifier
                .verifyFreshPrivateDatabaseAccess(in: container)
        } catch {
            try Task.checkCancellation()
            throw AppleAccountBoundaryResolutionError.blocked(
                .identityUnavailable
            )
        }
        let recordID: CKRecord.ID
        do {
            recordID = try await container.userRecordID()
        } catch {
            try Task.checkCancellation()
            throw AppleAccountBoundaryResolutionError.blocked(
                .identityUnavailable
            )
        }
        try Task.checkCancellation()
        guard recordID == recordIDBeforeProbe else {
            // The Apple Account changed while the network proof was in
            // flight. Neither identity is safe to mount in this attempt.
            throw AppleAccountBoundaryResolutionError.blocked(
                .identityUnavailable
            )
        }
        let fingerprint = Self.fingerprint(
            containerIdentifier: containerIdentifier,
            recordID: recordID
        )
        guard AppleAccountFingerprint.isValid(fingerprint) else {
            throw AppleAccountBoundaryResolutionError.blocked(
                .invalidVerifiedIdentity
            )
        }
        var registry = try loadRegistry()
        let decision = registry.resolve(
            .verified(fingerprint: fingerprint),
            expectedBinding: expectedBinding
        )
        switch decision {
        case let .allow(binding):
            try Task.checkCancellation()
            return ResolvedAppleAccountBoundary(binding: binding)
        case let .block(reason):
            throw AppleAccountBoundaryResolutionError.blocked(reason)
        }
    }

    private func loadRegistry() throws -> AppleAccountNamespaceRegistry {
        guard let data = defaults.data(forKey: Self.registryDefaultsKey) else {
            return AppleAccountNamespaceRegistry()
        }
        do {
            return try JSONDecoder().decode(
                AppleAccountNamespaceRegistry.self,
                from: data
            )
        } catch {
            throw AppleAccountBoundaryResolutionError.blocked(
                .invalidStoredRegistry
            )
        }
    }

    private static func fingerprint(
        containerIdentifier: String,
        recordID: CKRecord.ID
    ) -> String {
        let source = [
            containerIdentifier,
            recordID.zoneID.ownerName,
            recordID.zoneID.zoneName,
            recordID.recordName
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(source.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

}

enum CloudAccountAvailability: Equatable, Sendable {
    case checking
    case available
    case simulator
    case noAccount
    case restricted
    case temporarilyUnavailable
    case unavailable

    var title: String {
        switch self {
        case .checking: "iCloudを確認中"
        case .available: "iCloudに接続できます"
        case .simulator: "iCloudは実機で確認できます"
        case .noAccount: "Apple Accountへのサインインが必要です"
        case .restricted: "この端末ではiCloudが制限されています"
        case .temporarilyUnavailable: "iCloudへ一時的に接続できません"
        case .unavailable: "iCloudの状態を確認できません"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "実績と進行中タイマーの保存先を確認しています"
        case .available:
            "実績・瓶・進行中タイマーを同じApple AccountのiPhone間で同期"
        case .simulator:
            "このSimulator専用の保存領域を使い、iPhone実機のiCloudデータとは同期しません"
        case .noAccount:
            "選択したiCloud保存を続けるには、Apple AccountへのサインインとiCloud接続が必要です"
        case .restricted:
            "iCloud保存を続けるには、スクリーンタイムや管理端末のiCloud設定を確認してください"
        case .temporarilyUnavailable:
            "起動・再開時の本人確認には通信が必要です。接続回復後に再試行してください"
        case .unavailable:
            "本人確認が完了するまで保存領域は開きません。iCloudと通信状態を確認してください"
        }
    }

    var symbol: String {
        switch self {
        case .checking: "icloud"
        case .available: "checkmark.icloud.fill"
        case .simulator: "iphone.and.arrow.forward"
        case .noAccount, .restricted, .temporarilyUnavailable, .unavailable:
            "exclamationmark.icloud.fill"
        }
    }

    var isAvailable: Bool { self == .available }

    /// Simulator builds use a deliberately CloudKit-free local store. Neither
    /// retrying nor opening this app's Settings page can change that build-time
    /// choice, so presenting those recovery actions would be misleading.
    var showsRefreshAction: Bool {
        self != .checking && self != .simulator
    }

    var showsSettingsShortcut: Bool {
        switch self {
        case .noAccount, .restricted, .temporarilyUnavailable, .unavailable:
            true
        case .checking, .available, .simulator:
            false
        }
    }
}

@MainActor
@Observable
final class CloudSyncMonitor {
    private(set) var availability: CloudAccountAvailability = .checking

    func refresh() async {
        availability = .checking
#if targetEnvironment(simulator)
        // CKContainer(identifier:) raises an Objective-C exception (not a
        // catchable Swift Error) when the simulator app is installed from an
        // unsigned build and therefore has no CloudKit entitlement. The local
        // demo/test store is deliberately CloudKit-free, so report that state
        // honestly instead of crashing when Settings opens.
        availability = .simulator
        return
#else
        do {
            let container = CKContainer(
                identifier: CloudSyncConfiguration
                    .synchronizedDataContainerIdentifier
            )
            switch try await container.accountStatus() {
            case .available:
                let recordIDBeforeProbe = try await container.userRecordID()
                try await CloudKitOnlineAccountVerifier
                    .verifyFreshPrivateDatabaseAccess(in: container)
                let recordIDAfterProbe = try await container.userRecordID()
                guard recordIDBeforeProbe == recordIDAfterProbe else {
                    availability = .unavailable
                    return
                }
                availability = .available
            case .noAccount:
                availability = .noAccount
            case .restricted:
                availability = .restricted
            case .temporarilyUnavailable:
                availability = .temporarilyUnavailable
            case .couldNotDetermine:
                availability = .unavailable
            @unknown default:
                availability = .unavailable
            }
        } catch {
            availability = .unavailable
        }
#endif
    }
}

struct CloudSyncSettingsSection: View {
    let persistenceMode: PersistenceLaunchMode

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var monitor = CloudSyncMonitor()

    @ViewBuilder
    var body: some View {
        if persistenceMode == .localOnly {
            localOnlySection
        } else {
            cloudSection
        }
    }

    private var localOnlySection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text("このiPhoneだけに保存")
                        .font(.headline)
                    Text("iCloudへの自動送信・自動切り替えはありません")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                }
            } icon: {
                Image(systemName: "iphone")
                    .foregroundStyle(PomoGemTheme.amber)
            }

            Text("Version 1では保存方式を変更できません。iCloud同期を新しく始めるには、必要なら先に設定の「データを書き出す」でJSONを外部へ保管し、アプリを削除して再インストールしてください。削除するとこのiPhone内の記録は消えます。JSONはアプリへ再読込できないため、新しいiCloudの記録には引き継がれません。")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("保存方式")
        } footer: {
            Text("この選択は、意図しないアカウントへの記録混入を避けるため、このインストール中は固定されます。")
        }
    }

    private var cloudSection: some View {
        Section {
            HStack(alignment: .top, spacing: 13) {
                Group {
                    if monitor.availability == .checking {
                        ProgressView()
                            .tint(PomoGemTheme.amber)
                    } else {
                        Image(systemName: monitor.availability.symbol)
                            .foregroundStyle(
                                monitor.availability.isAvailable
                                    ? PomoGemTheme.amber
                                    : Color.orange
                            )
                    }
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(monitor.availability.title)
                        .font(.headline)
                    Text(monitor.availability.detail)
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: 48)
            .accessibilityElement(children: .combine)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    syncStep(1, "同じApple Accountでサインイン")
                    syncStep(2, "iCloudで、ポモジェムの利用をオン")
                    syncStep(3, "新しい端末でアプリを開き、同期を待つ")
                    syncStep(4, "進行中なら「この端末で続ける」を選ぶ")
                    Text("同期は即時でない場合があります。タイマーの通知は最後に引き継いだ端末が担当しますが、元の端末がオフラインの場合は古い通知が一度届くことがあります。")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(.vertical, 8)
            } label: {
                Text("別のiPhone・機種変更後に続けるには")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tint(Color.white)
            .listRowBackground(Color.black)

            if monitor.availability.showsRefreshAction {
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    Label("iCloudの状態を再確認", systemImage: "arrow.clockwise")
                }
            }

            if monitor.availability.showsSettingsShortcut {
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                } label: {
                    Label("この端末の設定を開く", systemImage: "gear")
                }
            }
        } header: {
            Text("iCloudとデバイス")
        } footer: {
            Group {
                if monitor.availability == .simulator {
                    Text("SimulatorではApple Accountの接続状態を確認できません。iCloud同期はiPhone実機で確認してください。")
                } else {
                    Text("このiCloud保存方式では、起動・再開時にApple Accountをオンラインで確認できることが必要です。この表示はすべての記録が反映済みであることを示すものではありません。自前サーバーは使わず、あなたのiCloudプライベートデータベースだけで同期します。")
                }
            }
            // Native List footers lower opacity a second time. An explicit
            // semantic foreground keeps this operational warning readable at
            // accessibility sizes without making it compete with the heading.
            .foregroundStyle(PomoGemTheme.text.opacity(0.86))
        }
        .task { await monitor.refresh() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await monitor.refresh() }
        }
    }

    private func syncStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(number)")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(PomoGemTheme.background)
                .frame(width: 22, height: 22)
                .background(PomoGemTheme.amber, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("手順\(number)、\(text)")
    }
}
