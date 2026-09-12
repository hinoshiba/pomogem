import Foundation

enum CloudLaunchDeadlineError: Error, LocalizedError, Equatable {
    case expired, finished, operationsInFlight

    var errorDescription: String? {
        switch self {
        case .expired:
            "iCloudの確認に時間がかかっています。端末内の記録を保護しています。通信状態を確認して再試行してください。"
        case .finished, .operationsInFlight:
            "起動処理の状態が変わりました。もう一度お試しください。"
        }
    }
}

/// One foreground launch shares one absolute deadline, including time between
/// individual requests. Expiry invalidates the attempt before presenting its
/// terminal UI. This lease cannot interrupt a synchronous store constructor or
/// prove that a cancelled CloudKit task released its ModelContainer: the host
/// must still require all old containers to retire before mounting a fallback.
@MainActor
final class CloudLaunchDeadline {
    nonisolated static let existingStoreTimeout: TimeInterval = 12
    nonisolated static let initialStoreTimeout: TimeInterval = 30

    private enum State { case active, expired, cancelled, finished }
    private var state: State = .active
    private let expiresAt: TimeInterval
    private let now: @MainActor () -> TimeInterval
    private let invalidateAttempt: @MainActor () -> Void
    private let onExpiry: @MainActor () -> Void
    private var timer: Task<Void, Never>?
    private var waiters: [UUID: (Error) -> Void] = [:]
    private var work: [UUID: Task<Void, Never>] = [:]

    init(
        timeout: TimeInterval,
        invalidateAttempt: @escaping @MainActor () -> Void,
        onExpiry: @escaping @MainActor () -> Void,
        now: @escaping @MainActor () -> TimeInterval = { ContinuousUptime.now() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.now = now
        self.invalidateAttempt = invalidateAttempt
        self.onExpiry = onExpiry
        let start = now()
        let end = start + timeout
        expiresAt = start.isFinite && timeout.isFinite && timeout > 0 && end.isFinite
            ? end : -Double.infinity
        timer = Task { @MainActor [weak self] in
            while let remaining = self?.remainingWhileActive {
                guard remaining > 0 else {
                    self?.expire()
                    return
                }
                do { try await sleep(remaining) }
                catch {
                    if !Task.isCancelled { self?.expire() }
                    return
                }
                guard !Task.isCancelled else { return }
                // A scheduler may wake early. Re-read the absolute clock;
                // never reset the launch budget or mistake a wake for expiry.
            }
        }
    }

    /// Call before every state mutation/publication and after each await that
    /// is not wrapped in run. The expiry callback is synchronous on MainActor.
    func check() throws {
        try Task.checkCancellation()
        if state == .active, (remainingWhileActive ?? 0) <= 0 { expire() }
        switch state {
        case .active: return
        case .expired: throw CloudLaunchDeadlineError.expired
        case .cancelled: throw CancellationError()
        case .finished: throw CloudLaunchDeadlineError.finished
        }
    }

    /// A continuation releases the caller even if the dependency ignores
    /// cancellation. Late values/errors cannot complete a waiter a second time.
    /// The operation must still validate its lease before its own side effects.
    func run<Value>(
        validate: @escaping @MainActor () throws -> Void = {},
        operation: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        try check()
        try validate()
        let id = UUID()
        let value: Value = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do { try check(); try validate() }
                catch { continuation.resume(throwing: error); return }
                waiters[id] = { continuation.resume(throwing: $0) }
                work[id] = Task { @MainActor in
                    let result: Result<Value, Error>
                    do { result = .success(try await operation()) }
                    catch { result = .failure(error) }
                    do {
                        try self.check()
                        try validate()
                        guard self.removeWaiter(id) else { return }
                        continuation.resume(with: result)
                    } catch {
                        guard self.removeWaiter(id) else { return }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel() }
        }
        try check()
        try validate()
        return value
    }

    /// Superseding a launch/scene cancels its waiters without timeout UI.
    func cancel() {
        guard state == .active else { return }
        state = .cancelled
        stopWork(error: CancellationError())
    }

    /// Disarm only after all awaited work finished and publication is ready.
    /// Completion does not grant a new lease or extend the original deadline.
    func finish() throws {
        try check()
        guard waiters.isEmpty else { throw CloudLaunchDeadlineError.operationsInFlight }
        state = .finished
        timer?.cancel()
        timer = nil
    }

    private var remainingWhileActive: TimeInterval? {
        guard state == .active else { return nil }
        let current = now()
        guard current.isFinite else { return 0 }
        return max(0, expiresAt - current)
    }

    private func expire() {
        guard state == .active else { return }
        state = .expired
        // Callback order is an invariant: even a reentrant terminal UI must
        // observe a revoked attempt and cannot publish an older candidate.
        invalidateAttempt()
        stopWork(error: CloudLaunchDeadlineError.expired, beforeResuming: onExpiry)
    }

    private func removeWaiter(_ id: UUID) -> Bool {
        work[id] = nil
        return waiters.removeValue(forKey: id) != nil
    }

    private func stopWork(error: Error, beforeResuming: () -> Void = {}) {
        timer?.cancel()
        timer = nil
        let tasks = Array(work.values)
        let pending = Array(waiters.values)
        work.removeAll()
        waiters.removeAll()
        tasks.forEach { $0.cancel() }
        beforeResuming()
        pending.forEach { $0(error) }
    }
}
