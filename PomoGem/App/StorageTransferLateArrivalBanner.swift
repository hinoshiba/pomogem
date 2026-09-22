import SwiftUI

/// PLAN Step 9 / §6.5. What the app says after a committed device → iCloud
/// replacement when the server turns out to hold user records the committed
/// payload did not.
///
/// `Docs/MultiDeviceCloudSafety.md` defect 1 — an already-running or
/// older-build installation flushing pre-purge rows into the recreated zone —
/// cannot be prevented by this design, and is openly not promised. This is the
/// one thing that IS promised about it: that it is looked for once, and said
/// out loud when it is seen. Neither offered action changes any data; the
/// banner is hedged because the detector is bounded and a device that flushes
/// days later is never caught.
struct StorageTransferLateArrivalPresentation: Equatable {
    /// Scoped to the session that evaluated the receipt, so a banner cannot
    /// outlive the mount it describes.
    let sessionID: UUID
    /// The user-recognizable models that grew, for diagnostics. The copy never
    /// names them: a count of rows is not something to act on.
    let models: [String]
    /// 「このまま使う」. Dismissal is not a decision about data.
    let dismiss: () -> Void
    /// 「設定を開く」, where both directional doors live.
    let openSettings: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionID == rhs.sessionID && lhs.models == rhs.models
    }
}

private struct StorageTransferLateArrivalKey: EnvironmentKey {
    static let defaultValue: StorageTransferLateArrivalPresentation? = nil
}

extension EnvironmentValues {
    var storageTransferLateArrival: StorageTransferLateArrivalPresentation? {
        get { self[StorageTransferLateArrivalKey.self] }
        set { self[StorageTransferLateArrivalKey.self] = newValue }
    }
}

extension Notification.Name {
    /// Posted by the late-arrival banner's 「設定を開く」. The banner sits above
    /// the session content and has no access to the router that owns
    /// navigation, so the request travels one hop rather than threading a
    /// closure through every layer in between.
    static let pomogemOpenStorageSettings = Notification.Name("pomogem.open-storage-settings")
}

struct StorageTransferLateArrivalBanner: View {
    let presentation: StorageTransferLateArrivalPresentation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.system(size: 18))
                    .accessibilityHidden(true)
                Text(StorageTransferOverwriteCopy.lateArrival)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("storage-overwrite-late-arrival")
            }
            controls
        }
        .foregroundStyle(PomoGemTheme.text)
        .padding(12)
        .background(PomoGemTheme.background)
    }

    @ViewBuilder
    private var controls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) { settingsButton; dismissButton }
        } else {
            HStack(spacing: 8) { settingsButton; dismissButton; Spacer(minLength: 0) }
        }
    }

    private var settingsButton: some View {
        // The chrome lives inside the label, as in `CloudOfflineBanner`, so the
        // 44 pt target is the button's own hit area rather than padding around
        // a text-sized one.
        Button(action: presentation.openSettings) {
            Text(StorageTransferOverwriteCopy.lateArrivalOpenSettings)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 44)
                .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("storage-overwrite-late-arrival-settings")
    }

    private var dismissButton: some View {
        Button(action: presentation.dismiss) {
            Text(StorageTransferOverwriteCopy.lateArrivalDismiss)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .frame(minWidth: 44, minHeight: 44)
                .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("storage-overwrite-late-arrival-dismiss")
    }
}
