import Foundation

/// The receipt lock is deliberately separate from the monitoring lock. The
/// main actor may close the receipt gate while a slow OS registration is busy.
struct ScreenTimeContextBinding: Equatable {
    let contextKey: String
    let dataEpochID: UUID?

    func matches(_ state: ScreenTimeState) -> Bool {
        state.contextKey == contextKey && state.dataEpochID == dataEpochID
    }
}

final class ScreenTimeContextLease: @unchecked Sendable {
    let binding: ScreenTimeContextBinding
    private let lock = NSLock()
    private var valid = true

    init(binding: ScreenTimeContextBinding) { self.binding = binding }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        valid = false
    }

    // Hold this only for short ledger operations, never an OS framework call.
    func whileCurrent<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard valid else { throw ScreenTimeError.unboundContext }
        return try operation()
    }
}

protocol ScreenTimeMonitoringDriving: AnyObject {
    func stop()
    func invalidateAuthorizationIfNeeded() throws
    func synchronize(now: Date) throws -> Bool
}

extension ScreenTimeMonitoring: ScreenTimeMonitoringDriving {}

/// FIFO submission happens on the main actor, but neither waiting for the
/// cross-process monitoring lock nor calling DeviceActivity runs there.
final class ScreenTimeMonitoringWorker {
    private let queue = DispatchQueue(label: "com.hinoshiba.pomogem.screen-time-monitoring", qos: .userInitiated)
    let store: ScreenTimeStore
    let monitoring: ScreenTimeMonitoringDriving

    init(store: ScreenTimeStore, monitoring: ScreenTimeMonitoringDriving) {
        self.store = store
        self.monitoring = monitoring
    }

    @MainActor
    func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }

    func retire(_ binding: ScreenTimeContextBinding) {
        queue.async { [self] in
            try? store.withMonitoringLock {
                guard binding.matches(try store.snapshot()) else { return }
                monitoring.stop()
                try store.update { state in
                    guard binding.matches(state) else { return }
                    state.contextIsActive = false
                    for index in state.runs.indices { state.runs[index].active = false }
                    state.pruneConsumedRuns()
                }
            }
        }
    }
}
