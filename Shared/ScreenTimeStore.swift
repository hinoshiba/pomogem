import Darwin
import Foundation

/// A small device-local ledger shared with the monitor extension. The flock is
/// on a separate, stable inode; atomic replacement of the JSON cannot bypass it.
/// Tokens never enter SwiftData, CloudKit, diagnostics, or exported documents.
final class ScreenTimeStore {
    static let appGroupID = "group.com.hinoshiba.pomogem"
    private let directory: URL?

    init(directory: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)) {
        self.directory = directory?.appendingPathComponent("ScreenTime", isDirectory: true)
    }

    func snapshot() throws -> ScreenTimeState { try withState(write: false) { $0 } }

    @discardableResult
    func update<T>(_ operation: (inout ScreenTimeState) throws -> T) throws -> T {
        try withState(write: true, operation)
    }

    func pendingLearningReceipts(limit: Int = 64) throws -> [ScreenTimeReceipt] {
        try snapshot().pendingLearningReceipts(limit: limit)
    }

    func acknowledgeLearningReceipts(ids: [UUID]) throws {
        try update { $0.acknowledge(Set(ids)) }
    }

    func record(runID: UUID, threshold: Int, now: Date = Date()) throws {
        try update { $0.record(runID: runID, threshold: threshold, now: now) }
    }

    /// Complete app erasure also owns this App Group. Keep both stable locks
    /// while stopping callbacks and replacing even an unreadable ledger.
    func eraseAllData(stoppingMonitoring: () -> Void) throws {
        guard directory != nil else {
            stoppingMonitoring()
            return
        }
        try withMonitoringLock {
            stoppingMonitoring()
            try withState(write: true, discardingExisting: true) { _ in }
        }
    }

    /// Serialize registration across the app and extension separately from the
    /// receipt lock. Framework calls can trigger callbacks that write receipts.
    func withMonitoringLock<T>(_ operation: () throws -> T) throws -> T {
        guard let directory else { throw ScreenTimeError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("monitoring.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ScreenTimeError.unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ScreenTimeError.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func withState<T>(write: Bool, discardingExisting: Bool = false, _ operation: (inout ScreenTimeState) throws -> T) throws -> T {
        guard let directory else { throw ScreenTimeError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Exclude opaque Family Controls tokens and the ledger from cloud backups.
        var localDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try localDirectory.setResourceValues(values)
        let lockPath = directory.appendingPathComponent("ledger.lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ScreenTimeError.unavailable }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw ScreenTimeError.unavailable }
        defer { flock(descriptor, LOCK_UN) }
        let url = directory.appendingPathComponent("ledger.json")
        var state: ScreenTimeState
        if !discardingExisting, FileManager.default.fileExists(atPath: url.path) {
            do {
                state = try JSONDecoder().decode(ScreenTimeState.self, from: Data(contentsOf: url))
                guard state.isValid else { throw ScreenTimeError.corruptedState }
            } catch { throw ScreenTimeError.corruptedState }
        } else {
            state = ScreenTimeState()
        }
        let result = try operation(&state)
        if write {
            guard state.isValid else { throw ScreenTimeError.corruptedState }
            try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return result
    }
}
