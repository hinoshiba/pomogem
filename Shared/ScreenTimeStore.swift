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

    /// Returns whether the ledger actually advanced, so the extension can log
    /// an awarded callback apart from one its fences discarded.
    @discardableResult
    func record(runID: UUID, threshold: Int, now: Date = Date()) throws -> Bool {
        try update { state in
            let before = state.runs.first { $0.id == runID }?.highestThreshold
            state.record(runID: runID, threshold: threshold, now: now)
            let after = state.runs.first { $0.id == runID }?.highestThreshold
            return after != nil && after != before
        }
    }

    /// Diagnostics only: bumps counters in a ledger that already exists.
    ///
    /// Never creates one. A DeviceActivity callback can reach the extension
    /// before the app has ever bound a ledger, and a file written there would
    /// be an owner-less state with a fresh epoch that no user action asked for.
    /// Never throws either: a callback's real work must not be lost to a
    /// failed count, and a ledger that cannot be written cannot record its own
    /// unavailability anyway.
    func countCallback(_ operation: (inout ScreenTimeState) -> Void) {
        guard ledgerExists else { return }
        try? update { operation(&$0) }
    }

    private var ledgerExists: Bool {
        guard let directory else { return false }
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("ledger.json").path
        )
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
    /// `timeout` bounds the wait and throws `unavailable` instead: the app can
    /// be suspended while it holds this lock, and a monitor extension that
    /// blocks in flock waiting for it is killed for running too long.
    func withMonitoringLock<T>(timeout: TimeInterval? = nil, _ operation: () throws -> T) throws -> T {
        guard let directory else { throw ScreenTimeError.unavailable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("monitoring.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ScreenTimeError.unavailable }
        defer { close(descriptor) }
        try Self.lockExclusively(descriptor, timeout: timeout)
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private static let monitoringLockPollInterval: TimeInterval = 0.05

    private static func lockExclusively(_ descriptor: Int32, timeout: TimeInterval?) throws {
        guard let timeout else {
            guard flock(descriptor, LOCK_EX) == 0 else { throw ScreenTimeError.unavailable }
            return
        }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return }
            guard errno == EWOULDBLOCK else { throw ScreenTimeError.unavailable }
            guard Date() < deadline else { throw ScreenTimeError.unavailable }
            Thread.sleep(forTimeInterval: monitoringLockPollInterval)
        }
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
