import Foundation

/// A pre-construction check cannot authorize publication after asynchronous
/// history imports and identity checks. Re-read dataset authority after that
/// work, and reject both cancellation and a revoked mount before returning.
@MainActor
enum StorageTransferHostCloudPublicationGate {
    static func verify<Value>(
        prepareCandidate: @MainActor () async throws -> Value,
        verifyLatestDataset: @MainActor () async throws -> Void,
        validateMount: @MainActor () throws -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        try validateMount()
        let candidate = try await prepareCandidate()
        try Task.checkCancellation()
        try validateMount()
        try await verifyLatestDataset()
        try Task.checkCancellation()
        try validateMount()
        return candidate
    }
}
