import Foundation

enum StorageTransferReleaseError: Error, LocalizedError, Equatable {
    case cloudReplacementUnavailable

    var errorDescription: String? {
        "複数端末での同時操作から記録を保護するため、iCloudの置き換えと、その復旧の再開は一時的に利用できません。端末のデータと復旧用コピーは削除せず保持します。"
    }
}

/// The control-record CAS does not serialize two installations resuming the
/// same replacement. A previously authorized zone deletion can arrive after
/// another installation commits. Keep destructive replacement unavailable in
/// the ordinary app until that distributed ownership gap is resolved.
struct StorageTransferReleasePolicy: Equatable, Sendable {
    static let standard = Self(allowsCloudReplacement: false)
    let allowsCloudReplacement: Bool

    private init(allowsCloudReplacement: Bool) {
        self.allowsCloudReplacement = allowsCloudReplacement
    }

    #if DEBUG
    /// Only injected by unit tests or an explicitly opted-in, isolated physical
    /// Development harness. Neither app launch flags nor the normal live
    /// factory select this policy. It provides no multi-device safety claim.
    static let isolatedTesting = Self(allowsCloudReplacement: true)
    #endif

    func validate(_ choice: StorageTransferChoice) throws {
        guard !choice.replacesCloud || allowsCloudReplacement else {
            throw StorageTransferReleaseError.cloudReplacementUnavailable
        }
    }
}
