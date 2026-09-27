import Foundation
import UIKit

/// settings-07. What support needs to reproduce a report, filled in so
/// nobody has to look it up: the app and iOS versions, the iPhone model,
/// where records are kept and whether Pro is owned. Never any record content,
/// theme name, memo, account identifier or Screen Time diagnostic. The
/// person reads the whole draft in their mail app and sends it themselves
/// (PRIVACY.md: nothing is sent automatically).
struct SupportMailDiagnostics: Equatable, Sendable {
    enum Storage: Equatable, Sendable {
        case iCloud
        case iCloudOffline
        case thisiPhone
        case preview
    }

    enum ProStatus: Equatable, Sendable {
        case owned
        case awaitingApproval
        case notOwned
    }

    let appVersion: String
    let systemVersion: String
    let deviceModel: String
    let storage: Storage
    let pro: ProStatus

    @MainActor
    static func current(
        persistenceMode: PersistenceLaunchMode,
        isCloudOfflineSession: Bool,
        purchase: PurchaseManager
    ) -> SupportMailDiagnostics {
        let storage: Storage = switch persistenceMode {
        case .cloudKit: isCloudOfflineSession ? .iCloudOffline : .iCloud
        case .localOnly: .thisiPhone
        case .inMemoryPreview, .persistentSimulator: .preview
        }
        let pro: ProStatus = purchase.isPro
            ? .owned
            : purchase.isAwaitingApproval() ? .awaitingApproval : .notOwned
        return SupportMailDiagnostics(
            appVersion: AppVersionText.current,
            systemVersion: UIDevice.current.systemVersion,
            deviceModel: hardwareModelIdentifier(),
            storage: storage,
            pro: pro
        )
    }

    /// 「iPhone13,1」: exact where a marketing name would be ambiguous.
    static func hardwareModelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}

enum SupportMailDraft {
    static var subject: String {
        String(localized: "ポモジェムについてのお問い合わせ", table: "Settings", comment: "Support mail subject")
    }

    static func body(for diagnostics: SupportMailDiagnostics) -> String {
        let prompt = String(
            localized: "（お問い合わせの内容をお書きください。不具合の場合は、操作の手順と起きたことを教えてください。）",
            table: "Settings",
            comment: "Support mail body: where the person writes their message"
        )
        let disclosure = String(
            localized: "以下はアプリが自動で記入しました。記録の内容やテーマ名は含まれていません。不要な行は消してから送れます。",
            table: "Settings",
            comment: "Support mail body: explains the filled-in lines below it"
        )
        let lines = [
            String(localized: "アプリ：ポモジェム \(diagnostics.appVersion)", table: "Settings",
                   comment: "Support mail line; the argument is the app version, e.g. 1.1.0 (10)"),
            String(localized: "iOS：\(diagnostics.systemVersion)", table: "Settings",
                   comment: "Support mail line; the argument is the iOS version, e.g. 26.5"),
            String(localized: "機種：\(diagnostics.deviceModel)", table: "Settings",
                   comment: "Support mail line; the argument is the model identifier, e.g. iPhone13,1"),
            String(localized: "保存先：\(storageName(diagnostics.storage))", table: "Settings",
                   comment: "Support mail line; the argument is where records are kept"),
            String(localized: "Pro：\(proName(diagnostics.pro))", table: "Settings",
                   comment: "Support mail line; the argument is whether Pro is owned")
        ]
        return ([prompt, "", "", "", "――――――――", disclosure] + lines).joined(separator: "\n")
    }

    static func url(for diagnostics: SupportMailDiagnostics) -> URL? {
        AppLinks.supportMail(subject: subject, body: body(for: diagnostics))
    }

    private static func storageName(_ storage: SupportMailDiagnostics.Storage) -> String {
        switch storage {
        case .iCloud:
            String(localized: "iCloud", table: "Settings", comment: "Support mail: records are kept in iCloud")
        case .iCloudOffline:
            String(localized: "iCloud（オフラインで利用中）", table: "Settings",
                   comment: "Support mail: iCloud mode, used offline from this iPhone's copy")
        case .thisiPhone:
            String(localized: "このiPhoneのみ", table: "Settings", comment: "Support mail: records are kept only on this iPhone")
        case .preview:
            String(localized: "プレビュー", table: "Settings", comment: "Support mail: a Debug preview build that keeps nothing")
        }
    }

    private static func proName(_ pro: SupportMailDiagnostics.ProStatus) -> String {
        switch pro {
        case .owned:
            String(localized: "利用中", table: "Settings", comment: "Support mail: Pro is owned")
        case .awaitingApproval:
            String(localized: "承認待ち", table: "Settings", comment: "Support mail: a Pro purchase awaits approval")
        case .notOwned:
            String(localized: "未購入", table: "Settings", comment: "Support mail: Pro is not owned")
        }
    }
}
