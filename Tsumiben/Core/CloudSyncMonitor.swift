import CloudKit
import Observation
import SwiftUI
import UIKit

enum CloudSyncConfiguration {
    static let containerIdentifier = "iCloud.com.hinoshiba.tsumiben"
}

enum CloudAccountAvailability: Equatable, Sendable {
    case checking
    case available
    case simulator
    case noAccount
    case restricted
    case temporarilyUnavailable
    case unavailable

    var title: String {
        switch self {
        case .checking: "iCloudを確認中"
        case .available: "iCloudに接続できます"
        case .simulator: "iCloudは実機で確認できます"
        case .noAccount: "Apple Accountへのサインインが必要です"
        case .restricted: "この端末ではiCloudが制限されています"
        case .temporarilyUnavailable: "iCloudへ一時的に接続できません"
        case .unavailable: "iCloudの状態を確認できません"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "実績と進行中タイマーの保存先を確認しています"
        case .available:
            "実績・瓶・進行中タイマーを同じApple AccountのiPhone間で同期"
        case .simulator:
            "このSimulator専用の保存領域を使い、iPhone実機のiCloudデータとは同期しません"
        case .noAccount:
            "同じApple Accountでサインインすると、機種変更後も続けられます"
        case .restricted:
            "スクリーンタイムや管理端末の設定を確認してください"
        case .temporarilyUnavailable:
            "端末内には保存済みです。通信回復後に自動で再試行します"
        case .unavailable:
            "端末内には保存済みです。iCloudと通信状態を確認してください"
        }
    }

    var symbol: String {
        switch self {
        case .checking: "icloud"
        case .available: "checkmark.icloud.fill"
        case .simulator: "iphone.and.arrow.forward"
        case .noAccount, .restricted, .temporarilyUnavailable, .unavailable:
            "exclamationmark.icloud.fill"
        }
    }

    var isAvailable: Bool { self == .available }

    /// Simulator builds use a deliberately CloudKit-free local store. Neither
    /// retrying nor opening this app's Settings page can change that build-time
    /// choice, so presenting those recovery actions would be misleading.
    var showsRefreshAction: Bool {
        self != .checking && self != .simulator
    }

    var showsSettingsShortcut: Bool {
        switch self {
        case .noAccount, .restricted, .temporarilyUnavailable, .unavailable:
            true
        case .checking, .available, .simulator:
            false
        }
    }
}

@MainActor
@Observable
final class CloudSyncMonitor {
    private(set) var availability: CloudAccountAvailability = .checking

    func refresh() async {
        availability = .checking
#if targetEnvironment(simulator)
        // CKContainer(identifier:) raises an Objective-C exception (not a
        // catchable Swift Error) when the simulator app is installed from an
        // unsigned build and therefore has no CloudKit entitlement. The local
        // demo/test store is deliberately CloudKit-free, so report that state
        // honestly instead of crashing when Settings opens.
        availability = .simulator
        return
#else
        do {
            let status = try await CKContainer(
                identifier: CloudSyncConfiguration.containerIdentifier
            ).accountStatus()
            availability = switch status {
            case .available: .available
            case .noAccount: .noAccount
            case .restricted: .restricted
            case .temporarilyUnavailable: .temporarilyUnavailable
            case .couldNotDetermine: .unavailable
            @unknown default: .unavailable
            }
        } catch {
            availability = .unavailable
        }
#endif
    }
}

struct CloudSyncSettingsSection: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var monitor = CloudSyncMonitor()

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 13) {
                Group {
                    if monitor.availability == .checking {
                        ProgressView()
                            .tint(TsumibenTheme.amber)
                    } else {
                        Image(systemName: monitor.availability.symbol)
                            .foregroundStyle(
                                monitor.availability.isAvailable
                                    ? TsumibenTheme.amber
                                    : Color.orange
                            )
                    }
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(monitor.availability.title)
                        .font(.headline)
                    Text(monitor.availability.detail)
                        .font(.caption)
                        .foregroundStyle(TsumibenTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: 48)
            .accessibilityElement(children: .combine)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    syncStep(1, "同じApple Accountでサインイン")
                    syncStep(2, "iCloud Driveと、つみべんのiCloud利用をオン")
                    syncStep(3, "新しい端末でアプリを開き、同期を待つ")
                    syncStep(4, "進行中なら「この端末で続ける」を選ぶ")
                    Text("同期は即時でない場合があります。タイマーの通知は最後に引き継いだ端末が担当しますが、元の端末がオフラインの場合は古い通知が一度届くことがあります。")
                        .font(.caption)
                        .foregroundStyle(TsumibenTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                .padding(.vertical, 8)
            } label: {
                Text("別のiPhone・機種変更後に続けるには")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .tint(Color.white)
            .listRowBackground(Color.black)

            if monitor.availability.showsRefreshAction {
                Button {
                    Task { await monitor.refresh() }
                } label: {
                    Label("iCloudの状態を再確認", systemImage: "arrow.clockwise")
                }
            }

            if monitor.availability.showsSettingsShortcut {
                Button {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                } label: {
                    Label("この端末の設定を開く", systemImage: "gear")
                }
            }
        } header: {
            Text("iCloudとデバイス")
        } footer: {
            Group {
                if monitor.availability == .simulator {
                    Text("SimulatorではApple Accountの接続状態を確認できません。iCloud同期はiPhone実機で確認してください。")
                } else {
                    Text("この表示はApple Accountへの接続可否であり、すべての記録が反映済みであることを示すものではありません。自前サーバーは使わず、あなたのiCloudプライベートデータベースだけで同期します。")
                }
            }
            // Native List footers lower opacity a second time. An explicit
            // semantic foreground keeps this operational warning readable at
            // accessibility sizes without making it compete with the heading.
            .foregroundStyle(TsumibenTheme.text.opacity(0.86))
        }
        .task { await monitor.refresh() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await monitor.refresh() }
        }
    }

    private func syncStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("\(number)")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(TsumibenTheme.background)
                .frame(width: 22, height: 22)
                .background(TsumibenTheme.amber, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("手順\(number)、\(text)")
    }
}
