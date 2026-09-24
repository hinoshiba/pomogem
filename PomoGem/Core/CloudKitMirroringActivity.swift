import CloudKit
import CoreData
import Observation
import OSLog
import SwiftUI

/// sync-04. What the mounted iCloud store's own mirroring reported, so
/// Settings can say when records last reached iCloud and when they cannot.
///
/// Before this the app never observed SwiftData/Core Data mirroring outcomes:
/// Settings based 「iCloudに接続できます」 on an account/zone read that cannot
/// fail for a full iCloud, so a user whose exports were rejected (most
/// commonly `quotaExceeded` on the free 5 GB tier) kept seeing a checkmark
/// beside 「同期」 while nothing was uploading.
///
/// Observational only: nothing here gates a mount, a transfer, the offline
/// route or any write. State lives in memory for the mounted session and is
/// cleared when that session retires. Each event is reduced at once to a kind,
/// a success flag, an end date and a coarse error class — no record, zone or
/// store identifier and no error text is kept, following the privacy rule in
/// `CloudAccountVerificationFailure`.
enum CloudKitMirroringErrorClass: Equatable, Sendable {
    /// The account is out of iCloud storage (top level or inside a partial failure).
    case quota
    /// Connectivity, throttling or conflicts CloudKit retries by itself.
    case transient
    /// Anything else. Shown only after it repeats.
    case persistent
}

struct CloudKitMirroringEventSummary: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case setup, importing, exporting }
    let kind: Kind
    let succeeded: Bool
    let endDate: Date
    let errorClass: CloudKitMirroringErrorClass?
}

enum CloudKitMirroringPolicy {
    /// Consecutive non-transient export failures before Settings says so.
    static let persistentFailureThreshold = 2

    private static let transientCodes: Set<CKError.Code> = [
        .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
        .zoneBusy, .serverResponseLost, .serverRecordChanged, .operationCancelled
    ]

    static func classify(_ error: Error?) -> CloudKitMirroringErrorClass? {
        guard let error else { return nil }
        if error is CancellationError { return .transient }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain { return .transient }
        guard nsError.domain == CKErrorDomain, let code = CKError.Code(rawValue: nsError.code) else {
            return .persistent
        }
        if code == .quotaExceeded { return .quota }
        if code == .partialFailure {
            let partial = (nsError.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error])?.values
                .map { classify($0) } ?? []
            if partial.contains(.quota) { return .quota }
            if !partial.isEmpty, partial.allSatisfy({ $0 == .transient }) { return .transient }
            return .persistent
        }
        return transientCodes.contains(code) ? .transient : .persistent
    }

    static func summary(of event: NSPersistentCloudKitContainer.Event) -> CloudKitMirroringEventSummary? {
        guard let endDate = event.endDate else { return nil }
        let kind: CloudKitMirroringEventSummary.Kind
        switch event.type {
        case .setup: kind = .setup
        case .import: kind = .importing
        case .export: kind = .exporting
        @unknown default: return nil
        }
        return CloudKitMirroringEventSummary(kind: kind, succeeded: event.succeeded, endDate: endDate,
            errorClass: event.succeeded ? nil : classify(event.error))
    }
}

struct CloudKitMirroringState: Equatable, Sendable {
    enum Issue: Equatable, Sendable {
        case quotaExceeded
        case persistentExportFailure
    }

    private(set) var lastExportSuccess: Date?
    private(set) var lastImportSuccess: Date?
    private(set) var consecutiveExportFailures = 0
    private(set) var issue: Issue?

    /// Something this device saved may not have reached iCloud yet.
    var mayHaveUnsentChanges: Bool { issue != nil }

    mutating func apply(_ event: CloudKitMirroringEventSummary) {
        switch event.kind {
        case .exporting:
            if event.succeeded {
                lastExportSuccess = max(lastExportSuccess ?? event.endDate, event.endDate)
                consecutiveExportFailures = 0
                issue = nil
                return
            }
            switch event.errorClass {
            case .quota:
                consecutiveExportFailures += 1
                issue = .quotaExceeded
            case .persistent, .none:
                consecutiveExportFailures += 1
                if issue != .quotaExceeded,
                   consecutiveExportFailures >= CloudKitMirroringPolicy.persistentFailureThreshold {
                    issue = .persistentExportFailure
                }
            case .transient:
                break
            }
        case .importing:
            if event.succeeded {
                lastImportSuccess = max(lastImportSuccess ?? event.endDate, event.endDate)
            }
        case .setup:
            break
        }
    }
}

/// App-scoped for the mounted online iCloud session: it must already be
/// listening when an export fails, long before the person opens Settings.
@MainActor
@Observable
final class CloudKitMirroringActivity {
    private(set) var state = CloudKitMirroringState()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private let center: NotificationCenter

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    var isObserving: Bool { observer != nil }

    /// A verified online session was published. Starts from a clean state.
    func start() {
        stop()
        state = CloudKitMirroringState()
        // SwiftData posts these with its own container as the object.
        observer = center.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
                                      object: nil, queue: .main) { [weak self] notification in
            guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event,
                  let summary = CloudKitMirroringPolicy.summary(of: event) else { return }
            MainActor.assumeIsolated { self?.record(summary) }
        }
    }

    /// The session retired, the account may have changed, or the app moved
    /// to the phone's copy: nothing observed so far describes what comes next.
    func stop() {
        if let observer { center.removeObserver(observer) }
        observer = nil
        state = CloudKitMirroringState()
    }

    func record(_ summary: CloudKitMirroringEventSummary) {
        state.apply(summary)
    }
}

private struct CloudKitMirroringActivityKey: EnvironmentKey {
    static let defaultValue: CloudKitMirroringActivity? = nil
}

extension EnvironmentValues {
    /// nil outside a mounted online iCloud session.
    var cloudKitMirroringActivity: CloudKitMirroringActivity? {
        get { self[CloudKitMirroringActivityKey.self] }
        set { self[CloudKitMirroringActivityKey.self] = newValue }
    }
}

/// The Settings copy, in one place so the fixture and the section agree.
enum CloudKitMirroringCopy {
    static var quotaTitle: String {
        String(localized: "iCloudの空き容量が不足しています", table: "Launch")
    }
    static var quotaDetail: String {
        String(localized: "最近の記録をiCloudへ送信できていません。記録はこのiPhoneに保存されています。iCloudに空きができると、自動で送信を再開します。", table: "Launch")
    }
    static var quotaSettingsHint: String {
        String(localized: "空き容量は「設定」アプリの一番上の名前 ＞「iCloud」で確認できます。", table: "Launch")
    }
    static var openSettings: String {
        String(localized: "「設定」アプリを開く", table: "Launch")
    }
    static var persistentFailure: String {
        String(localized: "iCloudへの送信がうまくいっていません。自動で再試行しています。記録はこのiPhoneに保存されています。", table: "Launch")
    }
    static func lastExport(_ relative: String) -> String {
        String(localized: "iCloudへの最終送信：\(relative)", table: "Launch",
               comment: "Settings: when this iPhone last sent records to iCloud, e.g. 3分前")
    }
    static var unsentWarning: String {
        String(localized: "このiPhoneには、まだiCloudへ送信できていない記録がある可能性があります。続ける前に「データを書き出す」で保存しておくと安心です。", table: "Launch")
    }
}
