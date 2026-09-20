import Foundation

enum StorageTransferReleaseError: Error, LocalizedError, Equatable {
    case cloudReplacementUnavailable
    case datasetOverwriteUnavailable
    case remoteReplacementResumeUnavailable

    var errorDescription: String? {
        switch self {
        case .cloudReplacementUnavailable:
            // UNCHANGED TEXT. It is pinned by the Settings UI tests and now
            // scopes only the legacy localOnly -> cloud Settings replacement.
            "複数端末での同時操作から記録を保護するため、iCloudの置き換えと、その復旧の再開は一時的に利用できません。端末のデータと復旧用コピーは削除せず保持します。"
        case .datasetOverwriteUnavailable:
            "この端末のデータでiCloudを置き換える操作は、いまは利用できません。端末のデータと復旧用コピーは削除せず保持します。"
        case .remoteReplacementResumeUnavailable:
            "別の端末が始めた置き換えを、このiPhoneからは再開できません。二重に実行しないよう停止しています。端末のデータと復旧用コピーは削除せず保持します。"
        }
    }
}

/// Three independent bits, so publishing one operation never publishes another.
///
/// - `allowsCloudReplacement` keeps the ORIGINAL prohibition exactly as
///   documented: the legacy `enableCloudReplacingCloud` localOnly -> cloud
///   replacement offered from Settings.
/// - `allowsDatasetOverwriteFromDevice` publishes only the new, generation
///   fenced `overwriteCloudFromDevice`.
/// - `allowsRemoteResumeBeforeReplacing` permits resuming a transaction this
///   installation did not start, and ONLY before the destructive phase, which
///   turns the `backupVerified -> replacing` CAS into an executor election
///   (Docs/MultiDeviceCloudSafety.md defect 2). The server manifest does not
///   record which replacement kind created a transaction, so once this bit is
///   true it also permits resuming a legacy `enableCloudReplacingCloud`
///   transaction. That is a deliberate, documented consequence, bounded to
///   `.staging` / `.backupVerified`.
///
/// Every bit is false in `standard`; nothing in the app constructs any other
/// policy. Defect 1 of Docs/MultiDeviceCloudSafety.md (an already-running or
/// older-build device pushing pre-purge rows into the recreated zone) is not
/// closed by any of these bits and stays open.
struct StorageTransferReleasePolicy: Equatable, Sendable {
    static let standard = Self(allowsCloudReplacement: false,
                               allowsDatasetOverwriteFromDevice: false,
                               allowsRemoteResumeBeforeReplacing: false)
    let allowsCloudReplacement: Bool
    let allowsDatasetOverwriteFromDevice: Bool
    let allowsRemoteResumeBeforeReplacing: Bool

    private init(allowsCloudReplacement: Bool,
                 allowsDatasetOverwriteFromDevice: Bool,
                 allowsRemoteResumeBeforeReplacing: Bool) {
        self.allowsCloudReplacement = allowsCloudReplacement
        self.allowsDatasetOverwriteFromDevice = allowsDatasetOverwriteFromDevice
        self.allowsRemoteResumeBeforeReplacing = allowsRemoteResumeBeforeReplacing
    }

    #if DEBUG
    /// Only injected by unit tests or an explicitly opted-in, isolated physical
    /// Development harness. Neither app launch flags nor the normal live
    /// factory select this policy. It provides no multi-device safety claim.
    static let isolatedTesting = Self(allowsCloudReplacement: true,
                                      allowsDatasetOverwriteFromDevice: true,
                                      allowsRemoteResumeBeforeReplacing: true)

    /// Unit tests only. The three bits are independent, so a test must be able
    /// to raise exactly one of them and prove the others stay closed.
    static func isolatedTestingPolicy(allowsCloudReplacement: Bool = false,
                                      allowsDatasetOverwriteFromDevice: Bool = false,
                                      allowsRemoteResumeBeforeReplacing: Bool = false) -> Self {
        Self(allowsCloudReplacement: allowsCloudReplacement,
             allowsDatasetOverwriteFromDevice: allowsDatasetOverwriteFromDevice,
             allowsRemoteResumeBeforeReplacing: allowsRemoteResumeBeforeReplacing)
    }
    #endif

    func validate(_ choice: StorageTransferChoice) throws {
        switch choice {
        case .disableCloudKeepingCopy, .enableCloudKeepingCloud:
            return
        case .enableCloudReplacingCloud:
            guard allowsCloudReplacement else {
                throw StorageTransferReleaseError.cloudReplacementUnavailable
            }
        case .overwriteCloudFromDevice:
            guard allowsDatasetOverwriteFromDevice else {
                throw StorageTransferReleaseError.datasetOverwriteUnavailable
            }
        }
    }

    /// Refuse before any remote read while the bit is closed: no observed phase
    /// can make a foreign resume legal then, and a closed refusal must not cost
    /// a network round trip or touch a single byte of preserved evidence.
    func requireRemoteResumeIsPublished() throws {
        guard allowsRemoteResumeBeforeReplacing else {
            throw StorageTransferReleaseError.remoteReplacementResumeUnavailable
        }
    }

    /// The server manifest does not record which replacement kind created it,
    /// so the gate is the PHASE, not the kind. Never permitted at `.replacing`
    /// or later: by then another installation has already been elected as the
    /// single executor of the zone deletion.
    func validateRemoteResume(_ phase: StorageTransferRecoveryControl.Phase) throws {
        guard allowsRemoteResumeBeforeReplacing,
              phase == .staging || phase == .backupVerified else {
            throw StorageTransferReleaseError.remoteReplacementResumeUnavailable
        }
    }
}
