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
                        Text("端末に保存")
                            .font(.caption.weight(.semibold))
                        Text("同期待ち")
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
            .accessibilityLabel("このiPhoneに保存・iCloud同期は待機中。詳細を表示")
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
                            Text("復旧手順")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(minWidth: 44, minHeight: 44)
                    .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("端末の記録を保持して復旧手順を表示")
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
                            Text(isChecking ? "確認中" : "同期を再開")
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
                .accessibilityLabel(isChecking ? "接続を確認中" : "同期を再開")
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

    private var details: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("このiPhoneに保存・iCloud同期は待機中")
                        .font(.headline)
                    Text(message)
                        .accessibilityIdentifier("cloud-offline-details-message")
                    if retry != nil {
                        Text("変更はこのiPhoneに保存されます。iCloudへの送信はまだ完了していません。")
                            .accessibilityIdentifier("cloud-offline-details-pending")
                        Text(CloudOfflineAccessPolicy.accessDescription)
                            .accessibilityIdentifier("cloud-offline-details-account")
                        if recoveryKind == nil {
                            Text("通信が戻ったら「同期を再開」で接続を確認できます。")
                        }
                        Text("同じアカウントとデータを確認できるまで、iCloudとの同期は始まりません。")
                            .accessibilityIdentifier("cloud-offline-details-recovery")
                        if recoveryKind == .storageTransfer, let reviewRecovery {
                            Text("端末の記録を保持して、この画面を閉じて利用を続けられます。復旧手順へ進むと現在の記録画面を閉じ、iCloudの状態を確認します。データの置き換えや削除には、その後の確認が必要です。")
                                .accessibilityIdentifier("cloud-offline-recovery-disclosure")
                            Button("復旧手順を確認", action: reviewRecovery)
                                .buttonStyle(PomoGemPrimaryButtonStyle())
                                .disabled(isChecking)
                                .accessibilityIdentifier("cloud-offline-review-recovery")
                        } else if recoveryKind == .resetHistory {
                            Text("記録の履歴が異なるため、自動で結合・送信できません。この画面を閉じて端末への記録を続けるか、設定の「データを書き出す」で記録を保存してください。同期の復旧についてはサポートへご相談ください。この操作で端末やiCloudの記録は削除しません。")
                                .accessibilityIdentifier("cloud-offline-history-options")
                            Link("サポートを見る", destination: AppLinks.support)
                                .buttonStyle(PomoGemSecondaryButtonStyle())
                        }
                    } else {
                        // A normally mirrored store also uses this banner when
                        // the path goes offline. It does not use manual retry
                        // admission and CloudKit continues its own scheduling.
                        Text("このiPhoneへの保存と、iCloudへの送信完了は別です。接続状態だけでは送信完了を確認できません。")
                            .accessibilityIdentifier("cloud-offline-details-pending")
                        Text("通信の回復後、iCloudの同期はシステムが再試行します。")
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
            .navigationTitle("同期の状態")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // A navigation toolbar may shrink the accessible button frame
                // even when its label requests 44 pt. A normal inset control
                // keeps that target size and reserves scroll space above it.
                Button {
                    showsDetails = false
                } label: {
                    Text("閉じる")
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
