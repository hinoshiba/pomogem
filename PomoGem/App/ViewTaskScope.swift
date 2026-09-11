import Foundation

/// Owns asynchronous work that may use a view's ModelContext after suspension.
/// Disappearance cancels accepted work and rejects late starts until the same
/// view appears again. System-owned effects must use cancellation-responsive
/// waiters so cancellation can actually release the view and its container.
@MainActor
final class ViewTaskScope {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isActive = true

    func activate() {
        isActive = true
    }

    @discardableResult
    func start(
        _ operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never>? {
        guard isActive else { return nil }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.tasks[id] = nil }
            guard !Task.isCancelled else { return }
            await operation()
        }
        tasks[id] = task
        return task
    }

    func cancelAll() {
        isActive = false
        let pending = Array(tasks.values)
        tasks.removeAll()
        pending.forEach { $0.cancel() }
    }
}
