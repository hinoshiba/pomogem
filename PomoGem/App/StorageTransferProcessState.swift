import Foundation

/// A process-lifetime fact, not a weak-container count. Core Data can retain
/// CloudKit work after the application's last container reference is released.
@MainActor
final class StorageTransferProcessMountHistory {
    private(set) var cloudMirrorWasOpened = false

    func markCloudMirrorOpened() { cloudMirrorWasOpened = true }
}

@MainActor
enum StorageTransferProcessState {
    private static let history = StorageTransferProcessMountHistory()

    static var cloudMirrorWasOpened: Bool { history.cloudMirrorWasOpened }

    /// Call before attempting construction: a throwing initializer can still
    /// have started asynchronous mirroring. There is deliberately no reset API.
    static func markCloudMirrorOpened() { history.markCloudMirrorOpened() }
}

/// The host runs this before artifact/profile validation and before any normal
/// store constructor. A pending or malformed journal can never fall through to
/// a writable source store merely because resuming it failed.
@MainActor
enum StorageTransferHostJournalGate {
    static func resumeIfPending(
        readPending: () throws -> Bool,
        requireReleased: () throws -> Void,
        validateAccess: () throws -> Void,
        resume: () async throws -> Void
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard try readPending() else { return false }
        try validateAccess()
        try requireReleased()
        try await resume()
        try Task.checkCancellation()
        try validateAccess()
        try requireReleased()
        guard try !readPending() else { throw StorageTransferError.staleTransaction }
        return true
    }
}
