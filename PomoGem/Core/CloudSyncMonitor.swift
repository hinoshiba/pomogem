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
    static let requestTimeout: TimeInterval = 15
    static let resourceTimeout: TimeInterval = 30

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
                CloudKitRoundTripLedger.record(.accountProbe)
                database.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
    }
}

enum CloudAccountVerificationStage: String, Equatable, Sendable {
    case verification = "全体確認"
    case accountStatus = "Apple Accountの状態"
    case identityBeforeProbe = "Apple Accountの識別"
    case privateDatabase = "iCloudへの接続"
    case identityAfterProbe = "Apple Accountの再確認"
}

/// Carries only an allowlisted category, stage and numeric CloudKit code.
/// CloudKit's localized error/userInfo may contain record or account data and
/// must never be used as presentation or diagnostic text at this boundary.
struct CloudAccountVerificationFailure: Error, LocalizedError, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case noAccount, restricted, temporarilyUnavailable, networkUnavailable
        case serviceUnavailable, configuration, permission, quota
        /// One verification read the account identity twice and the two reads
        /// disagreed with each other. This compares nothing to the stored
        /// binding, so it is a transient failure of the proof, never evidence
        /// that a different Apple Account is signed in.
        case identityUnstable
        case timedOut, unknown
    }

    let kind: Kind
    let stage: CloudAccountVerificationStage
    var cloudKitCode: Int? = nil
    var retryAfter: TimeInterval? = nil

    var errorDescription: String? {
        let message: String
        switch kind {
        case .noAccount:
            message = "Apple Accountへのサインインと、設定のiCloudでポモジェムの利用がオンになっていることを確認してください。"
        case .restricted:
            message = "この端末ではiCloudの利用が制限されています。スクリーンタイムや管理端末の設定を確認してください。"
        case .temporarilyUnavailable:
            message = "Apple Accountは現在iCloudを利用する準備ができていません。設定でApple Accountの確認を済ませ、しばらく待って再試行してください。"
        case .networkUnavailable:
            message = "iCloudに接続できません。Wi-Fiやモバイル通信、ポモジェムの通信設定を確認して再試行してください。"
        case .serviceUnavailable:
            message = "iCloudのサービスが一時的に混み合っているか、利用できません。しばらく待って再試行してください。"
        case .configuration:
            message = "このアプリのiCloud接続設定を確認できません。アプリを最新版へ更新し、解消しない場合はサポートへお問い合わせください。"
        case .permission:
            message = "iCloudへのアクセスが許可されませんでした。設定でポモジェムのiCloud利用を確認し、解消しない場合はサポートへお問い合わせください。"
        case .quota:
            message = "iCloudの空き容量を確認し、容量を確保してから再試行してください。"
        case .identityUnstable:
            message = "Apple Accountの識別を一度で確認できませんでした。そのまま再試行してください。"
        case .timedOut:
            message = "iCloudの確認に時間がかかっています。通信状態を確認して再試行してください。"
        case .unknown:
            message = "iCloudの状態を確認できません。再試行し、解消しない場合はサポートへお問い合わせください。"
        }
        let code = cloudKitCode.map { "・CloudKit \($0)" } ?? ""
        let waitHint: String
        if let retryAfter, retryAfter.isFinite, retryAfter > 0 {
            if retryAfter <= 3_600 {
                waitHint = "\n再試行まで約\(Int(ceil(retryAfter)))秒お待ちください。"
            } else {
                waitHint = "\niCloudが待機を指定しています。時間をおいて再試行してください。"
            }
        } else {
            waitHint = ""
        }
        return "\(message)\n確認箇所: \(stage.rawValue)\(code)\(waitHint)"
    }

    static func classify(
        _ error: Error,
        stage: CloudAccountVerificationStage
    ) -> Self {
        if let failure = error as? Self { return failure }
        let nsError = error as NSError
        guard nsError.domain == CKErrorDomain,
              let code = CKError.Code(rawValue: nsError.code) else {
            if nsError.domain == NSURLErrorDomain {
                return Self(kind: .networkUnavailable, stage: stage)
            }
            return Self(kind: .unknown, stage: stage)
        }
        let kind: Kind
        switch code {
        case .notAuthenticated: kind = .noAccount
        case .managedAccountRestricted: kind = .restricted
        case .accountTemporarilyUnavailable: kind = .temporarilyUnavailable
        case .networkUnavailable, .networkFailure: kind = .networkUnavailable
        case .serviceUnavailable, .requestRateLimited, .zoneBusy,
             .serverResponseLost: kind = .serviceUnavailable
        case .badContainer, .missingEntitlement, .badDatabase,
             .invalidArguments, .incompatibleVersion: kind = .configuration
        case .permissionFailure: kind = .permission
        case .quotaExceeded: kind = .quota
        default: kind = .unknown
        }
        return Self(
            kind: kind,
            stage: stage,
            cloudKitCode: code.rawValue,
            retryAfter: (nsError.userInfo[CKErrorRetryAfterKey] as? NSNumber)?
                .doubleValue
        )
    }

    /// A long server backoff belongs on the retry screen, not in a launch
    /// spinner. Never retry sooner than the server asks, including malformed
    /// non-finite values that cannot safely become a sleep duration.
    func automaticRetryDelay(defaultDelay: TimeInterval) -> TimeInterval? {
        guard kind == .networkUnavailable || kind == .serviceUnavailable else {
            return nil
        }
        let delay = max(defaultDelay, retryAfter ?? 0)
        guard retryAfter?.isFinite != false,
              delay.isFinite, delay >= 0, delay <= 3 else { return nil }
        return delay
    }
}

/// Server backoff outlives one launch/Settings refresh. Retain only sanitized
/// failures, never an account identity or a successful authorization. Continuous
/// uptime honors elapsed sleep time without trusting wall-clock changes.
actor CloudAccountVerificationBackoff {
    static let shared = CloudAccountVerificationBackoff()

    private struct Entry {
        let failure: CloudAccountVerificationFailure
        let retryAt: TimeInterval
    }

    private let now: @Sendable () -> TimeInterval
    private var entries: [String: Entry] = [:]

    init(now: @escaping @Sendable () -> TimeInterval = {
        ContinuousUptime.now()
    }) {
        self.now = now
    }

    func failureIfWaiting(
        for containerIdentifier: String
    ) -> CloudAccountVerificationFailure? {
        guard let entry = entries[containerIdentifier] else { return nil }
        let remaining = entry.retryAt - now()
        guard remaining > 0 else {
            entries[containerIdentifier] = nil
            return nil
        }
        var failure = entry.failure
        failure.retryAfter = remaining
        return failure
    }

    func record(
        _ failure: CloudAccountVerificationFailure,
        for containerIdentifier: String
    ) {
        guard failure.kind == .networkUnavailable
                || failure.kind == .serviceUnavailable,
              let delay = failure.retryAfter,
              delay.isFinite, delay > 0 else { return }
        let retryAt = now() + delay
        guard retryAt.isFinite else { return }
        // Overlapping verifications must not shorten a server deadline.
        if let previous = entries[containerIdentifier],
           previous.retryAt >= retryAt { return }
        entries[containerIdentifier] = Entry(failure: failure, retryAt: retryAt)
    }
}

struct CloudAccountVerificationClient: Sendable {
    var accountStatus: @Sendable () async throws -> CKAccountStatus
    var userRecordID: @Sendable () async throws -> CKRecord.ID
    var probePrivateDatabase: @Sendable () async throws -> Void
    var backoff: CloudAccountVerificationBackoff? = nil
    var containerIdentifier: String = ""

    static func live(containerIdentifier: String) -> Self {
        let container = CKContainer(identifier: containerIdentifier)
        return Self(
            accountStatus: { try await container.accountStatus() },
            userRecordID: { try await container.userRecordID() },
            probePrivateDatabase: {
                try await CloudKitOnlineAccountVerifier
                    .verifyFreshPrivateDatabaseAccess(in: container)
            },
            backoff: .shared,
            containerIdentifier: containerIdentifier
        )
    }
}

/// A continuation bridge is required here: a task group waits for a cancelled
/// child, but CloudKit's account/identity convenience APIs need not respond to
/// task cancellation. Late callbacks can finish their read without keeping the
/// launch screen waiting or publishing a late account identity.
private final class CloudAccountVerificationCompletion<Value: Sendable>:
    @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func install(tasks: [Task<Void, Never>]) {
        lock.lock()
        let isFinished = result != nil
        if !isFinished { self.tasks = tasks }
        lock.unlock()
        if isFinished { tasks.forEach { $0.cancel() } }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}

enum CloudAccountIdentityVerifier {
    static let verificationTimeout: TimeInterval = 45

    static func verify(
        using client: CloudAccountVerificationClient,
        timeout: TimeInterval = verificationTimeout,
        retryDelay: TimeInterval = 0.5
    ) async throws -> CKRecord.ID {
        let completion = CloudAccountVerificationCompletion<CKRecord.ID>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                let work = Task {
                    do {
                        for attempt in 0..<2 {
                            do {
                                let identity = try await verifyAttempt(using: client)
                                completion.finish(.success(identity))
                                return
                            } catch let failure as CloudAccountVerificationFailure {
                                guard attempt == 0,
                                      let delay = nextAttemptDelay(
                                        after: failure, defaultDelay: retryDelay
                                      ) else { throw failure }
                                try await Task.sleep(for: .seconds(delay))
                            }
                        }
                    } catch {
                        completion.finish(.failure(error))
                    }
                }
                let deadline = Task {
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                        completion.finish(.failure(CloudAccountVerificationFailure(
                            kind: .timedOut, stage: .verification
                        )))
                    } catch { /* A result or caller cancellation won. */ }
                }
                completion.install(tasks: [work, deadline])
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
        }
    }

    /// A second complete proof is worth running when the first one failed for
    /// a reason that says nothing about which account is signed in. Server
    /// backoff still owns its own deadline; an identity that disagreed with
    /// itself is repeated once at the caller's ordinary retry delay, because
    /// there is no server asking us to wait.
    static func nextAttemptDelay(
        after failure: CloudAccountVerificationFailure,
        defaultDelay: TimeInterval
    ) -> TimeInterval? {
        guard failure.kind == .identityUnstable else {
            return failure.automaticRetryDelay(defaultDelay: defaultDelay)
        }
        guard defaultDelay.isFinite, defaultDelay >= 0 else { return nil }
        return min(defaultDelay, 3)
    }

    private static func step<Value>(
        _ stage: CloudAccountVerificationStage,
        client: CloudAccountVerificationClient,
        operation: () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let pendingBackoff = await client.backoff?
            .failureIfWaiting(for: client.containerIdentifier)
        try Task.checkCancellation()
        if let pendingBackoff { throw pendingBackoff }
        do {
            let result = try await operation()
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let failure = CloudAccountVerificationFailure.classify(error, stage: stage)
            // A cancelled CloudKit convenience call may still return a real
            // server response. Preserve its sanitized retry deadline for the
            // next verifier, while the cancelled caller remains cancelled.
            await client.backoff?.record(failure, for: client.containerIdentifier)
            try Task.checkCancellation()
            throw failure
        }
    }

    private static func verifyAttempt(
        using client: CloudAccountVerificationClient
    ) async throws -> CKRecord.ID {
        let status = try await step(.accountStatus, client: client, operation: client.accountStatus)
        let failureKind: CloudAccountVerificationFailure.Kind?
        switch status {
        case .available: failureKind = nil
        case .noAccount: failureKind = .noAccount
        case .restricted: failureKind = .restricted
        case .temporarilyUnavailable: failureKind = .temporarilyUnavailable
        case .couldNotDetermine: failureKind = .unknown
        @unknown default: failureKind = .unknown
        }
        if let failureKind {
            throw CloudAccountVerificationFailure(
                kind: failureKind, stage: .accountStatus
            )
        }
        let before = try await step(.identityBeforeProbe, client: client, operation: client.userRecordID)
        try await step(.privateDatabase, client: client, operation: client.probePrivateDatabase)
        let after = try await step(.identityAfterProbe, client: client, operation: client.userRecordID)
        guard before == after else {
            // Two disagreeing reads inside one proof say only that the proof
            // is not usable. Which account is signed in is decided by the
            // NEXT complete proof, compared against the stored binding.
            throw CloudAccountVerificationFailure(
                kind: .identityUnstable, stage: .identityAfterProbe
            )
        }
        return after
    }
}

struct ResolvedAppleAccountBoundary: Equatable, Sendable {
    let binding: ActiveAccountLocalBinding
}

enum AppleAccountBoundaryResolutionError: LocalizedError, Equatable {
    case blocked(AppleAccountBoundaryBlockReason)
    case verification(CloudAccountVerificationFailure)

    var errorDescription: String? {
        switch self {
        case let .verification(failure):
            failure.errorDescription
        case .blocked(.identityUnavailable):
            "Apple AccountとiCloudを確認できません。確認が済むまで同期を停止します。利用できる端末データがある場合はオフラインで続けられます。"
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
    private let client: CloudAccountVerificationClient?
    private let verificationTimeout: TimeInterval
    private let retryDelay: TimeInterval
    private let transferJournalStore: StorageTransferJournalStore?

    init(
        defaults: UserDefaults = .standard,
        client: CloudAccountVerificationClient? = nil,
        verificationTimeout: TimeInterval = CloudAccountIdentityVerifier.verificationTimeout,
        retryDelay: TimeInterval = 0.5,
        transferJournalStore: StorageTransferJournalStore? = nil
    ) {
        self.defaults = defaults
        self.client = client
        self.verificationTimeout = verificationTimeout
        self.retryDelay = retryDelay
        self.transferJournalStore = transferJournalStore
    }

    static func hasPersistedRegistryHistory(
        defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.data(forKey: registryDefaultsKey) != nil
    }

    func resolve(
        expectedBinding: ActiveAccountLocalBinding? = nil
    ) async throws -> ResolvedAppleAccountBoundary {
        try Task.checkCancellation()
        let authorityBefore = try loadTransferAuthority()
        let containerIdentifier = CloudSyncConfiguration
            .synchronizedDataContainerIdentifier
        let recordID: CKRecord.ID
        do {
            recordID = try await CloudAccountIdentityVerifier.verify(
                using: client ?? .live(containerIdentifier: containerIdentifier),
                timeout: verificationTimeout,
                retryDelay: retryDelay
            )
        } catch let failure as CloudAccountVerificationFailure {
            throw AppleAccountBoundaryResolutionError.verification(failure)
        }
        try Task.checkCancellation()
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
        let authorityAfter = try loadTransferAuthority()
        guard authorityAfter == authorityBefore else {
            throw AppleAccountBoundaryResolutionError.blocked(.invalidStoredRegistry)
        }
        let decision = authorityAfter.decision(verifiedFingerprint: fingerprint,
            expectedBinding: expectedBinding, registry: registry)
            ?? registry.resolve(.verified(fingerprint: fingerprint), expectedBinding: expectedBinding)
        switch decision {
        case let .allow(binding):
            try Task.checkCancellation()
            return ResolvedAppleAccountBoundary(binding: binding)
        case let .block(reason):
            throw AppleAccountBoundaryResolutionError.blocked(reason)
        }
    }

    private func loadTransferAuthority() throws -> StorageTransferAccountNamespaceAuthority {
        do {
            let store: StorageTransferJournalStore?
            if let transferJournalStore { store = transferJournalStore }
            else if defaults === UserDefaults.standard { store = try .live() }
            else { store = nil }
            return try StorageTransferAccountNamespaceAuthority.read(from: store)
        } catch {
            throw AppleAccountBoundaryResolutionError.blocked(.invalidStoredRegistry)
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
            "iCloudとの通信を再確認してください。端末への記録は続けられます。この表示は同期完了を示すものではありません"
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
    private(set) var failure: CloudAccountVerificationFailure?
    private let client: CloudAccountVerificationClient?
    private let verificationTimeout: TimeInterval
    private let retryDelay: TimeInterval
    private var settledAvailability: CloudAccountAvailability = .unavailable
    private var settledFailure: CloudAccountVerificationFailure?
    private var refreshGeneration: UInt64 = 0
    private var refreshTask: Task<CKRecord.ID, Error>?

    init(
        client: CloudAccountVerificationClient? = nil,
        verificationTimeout: TimeInterval = CloudAccountIdentityVerifier.verificationTimeout,
        retryDelay: TimeInterval = 0.5
    ) {
        self.client = client
        self.verificationTimeout = verificationTimeout
        self.retryDelay = retryDelay
    }

    func refresh() async {
        guard !Task.isCancelled else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        refreshTask?.cancel()
        availability = .checking
        failure = nil
#if targetEnvironment(simulator)
        // Production simulator UI never constructs CKContainer; injected
        // clients exercise the same verification pipeline without entitlement.
        guard client != nil else {
            availability = .simulator
            settledAvailability = .simulator
            settledFailure = nil
            return
        }
#endif
        let client = client ?? .live(
            containerIdentifier: CloudSyncConfiguration.synchronizedDataContainerIdentifier
        )
        let timeout = verificationTimeout
        let retryDelay = retryDelay
        let task = Task {
            try await CloudAccountIdentityVerifier.verify(
                using: client, timeout: timeout, retryDelay: retryDelay
            )
        }
        refreshTask = task
        defer {
            if refreshGeneration == generation { refreshTask = nil }
        }
        do {
            _ = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard refreshGeneration == generation else { return }
            availability = .available
            settledAvailability = .available
            settledFailure = nil
        } catch is CancellationError {
            guard refreshGeneration == generation else { return }
            availability = settledAvailability
            failure = settledFailure
        } catch {
            guard refreshGeneration == generation else { return }
            guard !Task.isCancelled else {
                availability = settledAvailability
                failure = settledFailure
                return
            }
            let failure = CloudAccountVerificationFailure.classify(
                error, stage: .verification
            )
            self.failure = failure
            switch failure.kind {
            case .noAccount: availability = .noAccount
            case .restricted: availability = .restricted
            case .temporarilyUnavailable, .networkUnavailable,
                 .serviceUnavailable, .timedOut:
                availability = .temporarilyUnavailable
            default: availability = .unavailable
            }
            settledAvailability = availability
            settledFailure = failure
        }
    }

}

struct CloudSyncSettingsSection: View {
    let persistenceMode: PersistenceLaunchMode

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isCloudOfflineSession) private var isCloudOfflineSession
    /// device-01. Set for a session opened from a stop screen, whose sync
    /// does not resume when the connection does.
    @Environment(\.cloudConnectionPresentation) private var connectionPresentation
    /// sync-04. What the mounted store's mirroring reported (nil outside a
    /// mounted online iCloud session). Observational only.
    @Environment(\.cloudKitMirroringActivity) private var mirroringActivity
    @State private var monitor: CloudSyncMonitor

    @MainActor
    init(persistenceMode: PersistenceLaunchMode, monitor: CloudSyncMonitor? = nil) {
        self.persistenceMode = persistenceMode
        _monitor = State(initialValue: monitor ?? CloudSyncMonitor())
    }

    /// Mirroring results are shown only beside a successful account check:
    /// the account problem is the more useful thing to say otherwise.
    private var mirroringState: CloudKitMirroringState? {
        monitor.availability == .available ? mirroringActivity?.state : nil
    }

    private var showsQuotaIssue: Bool { mirroringState?.issue == .quotaExceeded }
    private var showsExportFailure: Bool { mirroringState?.issue == .persistentExportFailure }

    private var statusTitle: String {
        if showsQuotaIssue { return CloudKitMirroringCopy.quotaTitle }
        if showsExportFailure { return CloudKitMirroringCopy.persistentFailureTitle }
        return monitor.availability.title
    }

    private var statusDetail: String {
        if showsQuotaIssue { return CloudKitMirroringCopy.quotaDetail }
        if showsExportFailure { return CloudKitMirroringCopy.persistentFailureDetail }
        return monitor.failure?.errorDescription ?? monitor.availability.detail
    }

    /// The status icon's column plus its spacing: rows under the status start
    /// where its text does.
    private static let statusTextInset: CGFloat = 28 + 13

    @ViewBuilder
    var body: some View {
        if persistenceMode == .localOnly {
            localOnlySection
        } else if isCloudOfflineSession {
            offlineSection
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

            Text("iCloudの記録を使う場合は、下の保存先の設定で端末の記録が置き換わることを確認して切り替えられます。端末の記録でiCloudを置き換える操作は現在利用できません。アプリを削除すると、このiPhoneだけに保存した記録は失われます。")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("保存方式")
        } footer: {
            Text("保存先は自動で切り替わりません。切り替えには通信と、データの取り扱いの確認が必要です。")
        }
    }

    private var offlineSection: some View {
        let stopped = connectionPresentation?.recoveryKind != nil
        return Section {
            // The banner's own words, so the two never disagree about whether
            // sync is waiting for a connection or stopped until a decision.
            Label(stopped ? "このiPhoneに保存・iCloud同期は停止中" : "このiPhoneに保存・iCloud同期は待機中",
                  systemImage: "icloud.slash")
                .font(.headline)
            Text(stopped
                 ? "保存済みのテーマと記録を使い、タイマーや記録の追加を続けられます。この間の変更は端末に保存され、iCloudへは送信されません。通信が戻っても同期は自動では再開しません。再開する方法は、画面上部の「復旧手順」から確認できます。"
                 : "保存済みのテーマと記録を使い、タイマーや記録の追加を続けられます。この間の変更は端末に保存され、iCloudへはまだ送信されません。通信回復後、同じアカウントとデータを確認してから同期を再開します。")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text("別端末でデータが置き換わっている場合は、端末の記録を保持して同期を停止します。保存先の切り替えは、接続と内容を確認できてから行ってください。")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("iCloudとデバイス")
        }
    }

    private var cloudSection: some View {
        Section {
            HStack(alignment: .top, spacing: 13) {
                Group {
                    if monitor.availability == .checking {
                        ProgressView()
                            .tint(PomoGemTheme.amber)
                    } else if showsQuotaIssue || showsExportFailure {
                        // sync-04. Not the checkmark beside a sending problem.
                        Image(systemName: "exclamationmark.icloud.fill")
                            .foregroundStyle(Color.orange)
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
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: 48)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.icloud.status")

            if let mirroringState {
                mirroringStatusRow(mirroringState)
            }

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
            } else if showsQuotaIssue {
                // No public link opens iCloud storage itself; this opens the
                // Settings app and the hint above says where to look.
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                } label: {
                    Label(CloudKitMirroringCopy.openSettings, systemImage: "gear")
                }
                .accessibilityIdentifier("settings.icloud.quota.open-settings")
            }
        } header: {
            Text("iCloudとデバイス")
        } footer: {
            Group {
                if monitor.availability == .simulator {
                    Text("SimulatorではApple Accountの接続状態を確認できません。iCloud同期はiPhone実機で確認してください。")
                } else {
                    Text("通信が使えない場合も、前回確認済みの端末データがあれば利用を続けられます。初回の取得・保存先の切り替えには通信が必要です。この接続表示は、すべての記録の同期完了を示すものではありません。あなたのiCloudプライベートデータベースを使います。")
                }
            }
            // Native List footers lower opacity a second time. An explicit
            // semantic foreground keeps this operational warning readable at
            // accessibility sizes without making it compete with the heading.
            .foregroundStyle(PomoGemTheme.text.opacity(0.86))
        }
        .task { await monitor.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            Task { await monitor.refresh() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await monitor.refresh() }
        }
    }

    /// sync-04. One line under the status: where storage is short, that the
    /// app keeps retrying, or — when all is well — when records last reached
    /// iCloud. Its absence says nothing: exports run only when there are
    /// changes to send.
    @ViewBuilder
    private func mirroringStatusRow(_ state: CloudKitMirroringState) -> some View {
        switch state.issue {
        case .quotaExceeded:
            Text(CloudKitMirroringCopy.quotaSettingsHint)
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Self.statusTextInset)
                .accessibilityIdentifier("settings.icloud.quota.hint")
        case .persistentExportFailure:
            // The status above carries the title, the retry and where the
            // records are; nothing more to add on a line of its own.
            EmptyView()
        case nil:
            if let lastExport = state.lastExportSuccess {
                // Only the relative time ticks; the row stays one Label.
                Label {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(CloudKitMirroringCopy.lastExport(Self.relative(lastExport, now: context.date)))
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                } icon: {
                    Image(systemName: "icloud.and.arrow.up")
                        .foregroundStyle(PomoGemTheme.amber)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.icloud.last-export")
            }
        }
    }

    private static func relative(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else {
            return String(localized: "たった今", table: "Launch", comment: "Last iCloud send was less than a minute ago")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
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
