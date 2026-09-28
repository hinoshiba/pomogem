import Network
import Observation
import SwiftUI

private struct CloudOfflineSessionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// The selected mode is still iCloud, but this particular store session
    /// has no CloudKit transport. This is not an upload acknowledgement.
    var isCloudOfflineSession: Bool {
        get { self[CloudOfflineSessionKey.self] }
        set { self[CloudOfflineSessionKey.self] = newValue }
    }
}

/// Presentation values only. No persistence session or container is retained
/// here; account/recovery actions stay with the existing Host admission owner.
struct CloudConnectionPresentation {
    let sessionID: UUID
    let isChecking: Bool
    let message: String
    let retry: (() -> Void)?
    var recoveryKind: CloudOfflineRecoveryKind? = nil
    var reviewRecovery: (() -> Void)? = nil
}

private struct CloudConnectionPresentationKey: EnvironmentKey {
    static let defaultValue: CloudConnectionPresentation? = nil
}

extension EnvironmentValues {
    var cloudConnectionPresentation: CloudConnectionPresentation? {
        get { self[CloudConnectionPresentationKey.self] }
        set { self[CloudConnectionPresentationKey.self] = newValue }
    }
}

/// Shared by the session's Root and its full-screen focus/break presentations.
/// Keep the content's structural identity stable when connectivity changes.
struct CloudConnectionSessionContent<Content: View>: View {
    @Environment(\.cloudConnectionPresentation) private var presentation
    /// Non-blocking, and deliberately above the offline banner: it reports
    /// something that already happened to the data, not the transport.
    @Environment(\.storageTransferLateArrival) private var lateArrival
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // An outer safeAreaInset is insufficient around Root's ZStack and
        // nested NavigationStack: UIKit can still place its toolbar beneath
        // the inset's buttons. Allocate separate layout space instead.
        VStack(spacing: 0) {
            if let lateArrival {
                StorageTransferLateArrivalBanner(presentation: lateArrival)
                    .id(lateArrival.sessionID)
                    .fixedSize(horizontal: false, vertical: true)
                    .zIndex(2)
            }
            if let presentation {
                CloudOfflineBanner(isChecking: presentation.isChecking,
                    message: presentation.message, retry: presentation.retry,
                    recoveryKind: presentation.recoveryKind,
                    reviewRecovery: presentation.reviewRecovery)
                    .id(presentation.sessionID)
                    .fixedSize(horizontal: false, vertical: true)
                    .zIndex(1)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A network path is only a retry hint. It never proves an Apple Account,
/// CloudKit availability, dataset generation, or successful synchronization.
@MainActor @Observable
final class CloudNetworkPathObserver {
    private(set) var isOffline: Bool?
    private var isStarted = false
    private let lifetime = CloudNetworkMonitorLifetime()

    func start() {
        guard !isStarted else { return }
        isStarted = true
        let monitor = lifetime.monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor [weak self] in self?.isOffline = offline }
        }
        monitor.start(queue: DispatchQueue(label: "com.hinoshiba.pomogem.network-path"))
    }

}

/// NWPathMonitor is thread-safe; its cancellation must also be valid when the
/// final observable owner is released outside the main actor.
private final class CloudNetworkMonitorLifetime: @unchecked Sendable {
    let monitor = NWPathMonitor()
    deinit { monitor.cancel() }
}

struct CloudOfflineBanner: View {
    let isChecking: Bool
    let message: String
    let retry: (() -> Void)?
    var recoveryKind: CloudOfflineRecoveryKind? = nil
    var reviewRecovery: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                showsDetails = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "icloud.slash")
                        .font(.system(size: 18))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("端末に保存", tableName: "Launch",
                             comment: "Offline banner, first line: records are being saved on this device")
                            .font(.caption.weight(.semibold))
                        Text(syncIsStopped
                             ? String(localized: "同期停止中", table: "Launch",
                                      comment: "Offline banner, second line: iCloud sync is stopped until a decision")
                             : String(localized: "同期待ち", table: "Launch",
                                      comment: "Offline banner, second line: iCloud sync waits for a connection"))
                            .font(.caption)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "info.circle")
                        .font(.system(size: 16))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(statusTitle)。詳細を表示", tableName: "Launch",
                                     comment: "VoiceOver: offline banner button. %@ is the sync status title"))
            .accessibilityIdentifier("cloud-offline-details")

            Spacer(minLength: 0)

            if recoveryKind != nil {
                Button {
                    showsDetails = true
                } label: {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            Image(systemName: "exclamationmark.icloud")
                                .font(.system(size: 20))
                        } else {
                            Text("復旧手順", tableName: "Launch",
                                 comment: "Offline banner button: opens the recovery steps")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("端末の記録を保持して復旧手順を表示", tableName: "Launch",
                                         comment: "VoiceOver: offline banner recovery button"))
                .accessibilityIdentifier("cloud-offline-recovery-details")
            } else if let retry {
                Button(action: retry) {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            // A labelled icon leaves room for the readable,
                            // uncapped status text at accessibility sizes.
                            Image(systemName: isChecking ? "hourglass" : "arrow.clockwise")
                                .font(.system(size: 20))
                        } else {
                            Text(isChecking
                                 ? String(localized: "確認中", table: "Launch",
                                          comment: "Offline banner button while the connection is being checked")
                                 : String(localized: "同期を再開", table: "Launch",
                                          comment: "Offline banner button: re-check the connection and resume sync"))
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isChecking)
                .accessibilityLabel(isChecking
                    ? Text("接続を確認中", tableName: "Launch", comment: "VoiceOver: the connection is being checked")
                    : Text("同期を再開", tableName: "Launch",
                           comment: "Offline banner button: re-check the connection and resume sync"))
                .accessibilityIdentifier("cloud-offline-retry")
            }
        }
        .foregroundStyle(PomoGemTheme.text)
        .padding(12)
        .background(PomoGemTheme.background)
        // Identifiers belong to the controls. An identifier on this container
        // can replace the children's identifiers in SwiftUI's AX hierarchy.
        .sheet(isPresented: $showsDetails) {
            details
                .dynamicTypeSize(dynamicTypeSize)
                .presentationDetents([.large])
        }
    }

    /// device-01. A session opened from a stop screen (a storage-transfer stop
    /// or a reset-history difference) does not resume on its own: a restored
    /// connection meets the same stop. 「待ち」 would promise that it does, so
    /// such a session says that sync is stopped, and its banner carries
    /// 「復旧手順」 instead of 「同期を再開」.
    private var syncIsStopped: Bool { recoveryKind != nil }

    private var statusTitle: String {
        syncIsStopped
            ? String(localized: "このiPhoneに保存・iCloud同期は停止中", table: "Launch",
                     comment: "Sync status title: saving on this iPhone; iCloud sync is stopped until a decision")
            : String(localized: "このiPhoneに保存・iCloud同期は待機中", table: "Launch",
                     comment: "Sync status title: saving on this iPhone; iCloud sync waits for a connection")
    }

    private var details: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(statusTitle)
                        .font(.headline)
                        .accessibilityIdentifier("cloud-offline-details-title")
                    Text(message)
                        .accessibilityIdentifier("cloud-offline-details-message")
                    if retry != nil {
                        Text("変更はこのiPhoneに保存されます。iCloudへの送信はまだ完了していません。", tableName: "Launch")
                            .accessibilityIdentifier("cloud-offline-details-pending")
                        Text(CloudOfflineAccessPolicy.accessDescription)
                            .accessibilityIdentifier("cloud-offline-details-account")
                        if recoveryKind == nil {
                            Text("通信が戻ったら「同期を再開」で接続を確認できます。", tableName: "Launch",
                                 comment: "「同期を再開」 is the banner button's title")
                        }
                        Text("同じアカウントとデータを確認できるまで、iCloudとの同期は始まりません。", tableName: "Launch")
                            .accessibilityIdentifier("cloud-offline-details-recovery")
                        if recoveryKind == .storageTransfer, let reviewRecovery {
                            Text("端末の記録を保持して、この画面を閉じて利用を続けられます。復旧手順へ進むと現在の記録画面を閉じ、iCloudの状態を確認します。データの置き換えや削除には、その後の確認が必要です。", tableName: "Launch")
                                .accessibilityIdentifier("cloud-offline-recovery-disclosure")
                            Button(String(localized: "復旧手順を確認", table: "Launch"), action: reviewRecovery)
                                .buttonStyle(PomoGemPrimaryButtonStyle())
                                .disabled(isChecking)
                                .accessibilityIdentifier("cloud-offline-review-recovery")
                        } else if recoveryKind == .resetHistory {
                            Text("記録の履歴が異なるため、自動で結合・送信できません。この画面を閉じて端末への記録を続けるか、設定の「データを書き出す」で記録を保存してください。同期の復旧についてはサポートへご相談ください。この操作で端末やiCloudの記録は削除しません。", tableName: "Launch",
                                 comment: "「データを書き出す」 is the export button's title in Settings")
                                .accessibilityIdentifier("cloud-offline-history-options")
                            Link(String(localized: "サポートを見る", table: "Launch"), destination: AppLinks.support)
                                .buttonStyle(PomoGemSecondaryButtonStyle())
                        }
                    } else {
                        // A normally mirrored store also uses this banner when
                        // the path goes offline. It does not use manual retry
                        // admission and CloudKit continues its own scheduling.
                        Text("このiPhoneへの保存と、iCloudへの送信完了は別です。接続状態だけでは送信完了を確認できません。", tableName: "Launch")
                            .accessibilityIdentifier("cloud-offline-details-pending")
                        Text("通信の回復後、iCloudの同期はシステムが再試行します。", tableName: "Launch")
                            .accessibilityIdentifier("cloud-offline-details-recovery")
                    }
                }
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .foregroundStyle(PomoGemTheme.text)
            .background(PomoGemTheme.background)
            .navigationTitle(Text("同期の状態", tableName: "Launch"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // A navigation toolbar may shrink the accessible button frame
                // even when its label requests 44 pt. A normal inset control
                // keeps that target size and reserves scroll space above it.
                Button {
                    showsDetails = false
                } label: {
                    Text("閉じる", tableName: "Launch", comment: "Button: closes the sync status sheet")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.vertical, 8)
                        .foregroundStyle(PomoGemTheme.background)
                        .background(PomoGemTheme.amber, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cloud-offline-details-close")
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(PomoGemTheme.background)
            }
        }
    }
}
