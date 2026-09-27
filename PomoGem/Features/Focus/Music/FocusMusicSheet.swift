import MusicKit
import SwiftUI
import UIKit

/// Choose and control focus background music (D4.4b, Docs/FocusMusic.md).
/// The Music app plays; PomoGem stays in the foreground, so a running focus
/// is never interrupted. Permission is asked only from a tap here, and a
/// person without Apple Music sees Apple's own subscription offer.
struct FocusMusicSheet: View {
    let controller: FocusMusicController
    /// False while a focus is on screen (D4.1: no link-outs during a focus).
    /// Leaving PomoGem mid-focus can pause the timer, so the Settings button
    /// is replaced by a line saying where to change the permission later.
    let allowsLeavingApp: Bool

    @Environment(\.dismiss) private var dismiss
    @AppStorage(FocusMusicPreferences.sourceKey) private var chosenSourceID = ""
    @AppStorage(FocusMusicPreferences.autoplayKey) private var autoplay = FocusMusicPreferences.defaultAutoplay
    @State private var isOfferPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    introduction
                    status
                    if let hint = controller.hint {
                        Label {
                            Text(verbatim: hint.message)
                        } icon: {
                            Image(systemName: "info.circle")
                                .accessibilityHidden(true)
                        }
                        .font(.footnote)
                        .foregroundStyle(PomoGemTheme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("focus-music.hint")
                    }
                    sourceList
                    autoplayToggle
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(NightBackground())
            .navigationTitle(Text("集中用の音楽", tableName: "Focus"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton(
                        accessibilityLabel: String(
                            localized: "音楽の画面を閉じる",
                            table: "Focus",
                            comment: "VoiceOver label of the music sheet's close button"
                        ),
                        accessibilityIdentifier: "focus-music.close"
                    ) {
                        dismiss()
                    }
                }
            }
        }
        .foregroundStyle(PomoGemTheme.text)
        .musicSubscriptionOffer(isPresented: $isOfferPresented, options: offerOptions)
        .onChange(of: isOfferPresented) { _, isPresented in
            guard !isPresented else { return }
            Task { await controller.refresh(forceSubscriptionCheck: true) }
        }
        .task {
            await controller.refresh(forceSubscriptionCheck: true)
            await controller.loadCatalogTitlesIfNeeded()
        }
    }

    // MARK: - Sections

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ミュージックアプリで再生します。Apple Musicの登録が必要です。", tableName: "Focus")
                .font(.subheadline)
            Text("再生すると、ミュージックアプリの再生中のリストが入れ替わります。タイマーが終わっても音楽は止まりません。", tableName: "Focus")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var status: some View {
        switch controller.availability {
        case .checking:
            PomoGemCard {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Apple Musicを確認しています", tableName: "Focus")
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .needsAuthorization:
            statusCard(
                message: Text("ポモジェムから「ミュージック」アプリの再生を操作するには、Apple Musicへのアクセスを許可してください。", tableName: "Focus"),
                actionTitle: Text("Apple Musicへのアクセスを許可", tableName: "Focus"),
                identifier: "focus-music.authorize"
            ) {
                Task { await controller.requestAuthorization() }
            }
        case .denied:
            if allowsLeavingApp {
                statusCard(
                    message: Text("Apple Musicへのアクセスが許可されていません。「設定」アプリのポモジェムで「メディアとApple Music」をオンにすると使えます。", tableName: "Focus"),
                    actionTitle: Text("「設定」アプリを開く", tableName: "Focus"),
                    identifier: "focus-music.open-settings",
                    action: openSettings
                )
            } else {
                messageCard(
                    Text("Apple Musicへのアクセスが許可されていません。集中が終わってから、「設定」アプリのポモジェムで「メディアとApple Music」をオンにすると使えます。", tableName: "Focus")
                )
            }
        case .restricted:
            if allowsLeavingApp {
                statusCard(
                    message: Text("このiPhoneでは、スクリーンタイムなどの制限でApple Musicを利用できません。", tableName: "Focus"),
                    actionTitle: Text("「設定」アプリを開く", tableName: "Focus"),
                    identifier: "focus-music.open-settings",
                    action: openSettings
                )
            } else {
                messageCard(
                    Text("このiPhoneでは、スクリーンタイムなどの制限でApple Musicを利用できません。", tableName: "Focus")
                )
            }
        case .checkFailed:
            statusCard(
                message: Text("Apple Musicの登録状況を確認できませんでした。通信を確認して、もう一度お試しください。", tableName: "Focus"),
                actionTitle: Text("もう一度確認する", tableName: "Focus"),
                identifier: "focus-music.retry"
            ) {
                Task { await controller.refresh(forceSubscriptionCheck: true) }
            }
        case .subscriptionOffer:
            statusCard(
                message: Text("Apple Musicに登録すると、ここから再生できます。", tableName: "Focus"),
                actionTitle: Text("Apple Musicについて見る", tableName: "Focus"),
                identifier: "focus-music.offer"
            ) {
                isOfferPresented = true
            }
        case .unavailable:
            messageCard(Text("このiPhoneでは、Apple Musicの曲を再生できません。", tableName: "Focus"))
        case .ready:
            EmptyView()
        }
        // Always when ready; otherwise while the Music app has something to
        // pause or resume, so music started earlier can still be paused here.
        if controller.showsNowPlaying {
            nowPlayingCard
        }
    }

    private var nowPlayingCard: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 12) {
                nowPlayingLine
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("focus-music.now-playing")
                HStack(spacing: 12) {
                    Button {
                        Task { await controller.togglePlayback() }
                    } label: {
                        Label {
                            controller.isPlaying
                                ? Text("一時停止", tableName: "Focus", comment: "Pause the Music app")
                                : Text("再生", tableName: "Focus", comment: "Play the chosen focus music")
                        } icon: {
                            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        }
                    }
                    .buttonStyle(PomoGemCompactButtonStyle())
                    // A pause is always allowed, even while a start is in flight.
                    .disabled(
                        controller.transportToggle == .unavailable
                            || (controller.isBusy && controller.transportToggle != .pause)
                    )
                    .accessibilityIdentifier("focus-music.play-pause")

                    Button {
                        Task { await controller.skipToNext() }
                    } label: {
                        Label {
                            Text("次の曲", tableName: "Focus", comment: "Skip to the next track in the Music app")
                        } icon: {
                            Image(systemName: "forward.fill")
                        }
                    }
                    .buttonStyle(PomoGemCompactButtonStyle(isProminent: false))
                    .disabled(controller.isBusy || controller.nowPlaying.status == .stopped)
                    .accessibilityIdentifier("focus-music.next")
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var nowPlayingLine: Text {
        let title = controller.nowPlaying.title
        switch controller.nowPlaying.status {
        case .playing:
            if let title {
                return Text("再生中：\(title)", tableName: "Focus", comment: "Now playing line; the argument is the Music app's current track title")
            }
            return Text("再生中", tableName: "Focus", comment: "Now playing line without a track title")
        case .paused, .interrupted:
            if let title {
                return Text("一時停止中：\(title)", tableName: "Focus", comment: "Paused line; the argument is the Music app's current track title")
            }
            return Text("一時停止中", tableName: "Focus", comment: "Paused line without a track title")
        case .stopped:
            if selectedSource == nil {
                return Text("下から音楽を選ぶと再生が始まります。", tableName: "Focus")
            }
            return Text("再生していません", tableName: "Focus")
        }
    }

    private var sourceList: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("音楽を選ぶ", tableName: "Focus", comment: "Focus music list: its heading, and the timer button's VoiceOver action that opens it")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                ForEach(FocusMusicCatalog.sources) { source in
                    sourceRow(source)
                }
            }
        }
    }

    private func sourceRow(_ source: FocusMusicSource) -> some View {
        let isSelected = source.id == chosenSourceID
        // D4.3: without a way to play (no permission, or no subscription and
        // no offer) a row only remembers the choice and shows no play mark.
        let allowsPlayback = controller.availability.allowsRowPlayback
        return Button {
            Task {
                if await controller.choose(source) == .presentOffer {
                    isOfferPresented = true
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: source.kind == .station ? "dot.radiowaves.left.and.right" : "music.note.list")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PomoGemTheme.amber)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: controller.title(for: source))
                        .font(.system(.body, design: .rounded, weight: .bold))
                    Group {
                        switch source.kind {
                        case .playlist:
                            Text("プレイリスト", tableName: "Focus")
                        case .station:
                            Text("ステーション", tableName: "Focus", comment: "An Apple Music radio station")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : allowsPlayback ? "play.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? PomoGemTheme.amber : PomoGemTheme.muted)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(PomoGemTheme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PomoGemRowButtonStyle(isSelected: isSelected))
        .disabled(controller.isBusy)
        .accessibilityValue(
            isSelected
                ? Text("選択中", tableName: "Focus", comment: "VoiceOver value: this music is the chosen one")
                : Text("未選択", tableName: "Focus", comment: "VoiceOver value: this music is not chosen")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(
            allowsPlayback
                ? Text("選んで再生します", tableName: "Focus", comment: "VoiceOver hint of a music row")
                : Text("この音楽を選んでおきます。今は再生しません", tableName: "Focus", comment: "VoiceOver hint of a music row while Apple Music cannot play: the tap only remembers the choice")
        )
        .accessibilityIdentifier("focus-music.source.\(source.id)")
    }

    private var autoplayToggle: some View {
        PomoGemCard {
            Toggle(isOn: $autoplay) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("集中を始めたら再生する", tableName: "Focus")
                        .font(.system(.body, design: .rounded, weight: .bold))
                    Text("このiPhoneで集中を始めたときに、選んだ音楽を自動で再生します。ほかの音楽や音声を再生中のときは入れ替えません。", tableName: "Focus")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(PomoGemTheme.amber)
            .accessibilityIdentifier("focus-music.autoplay")
        }
    }

    // MARK: - Helpers

    private func messageCard(_ message: Text) -> some View {
        PomoGemCard {
            message
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusCard(
        message: Text,
        actionTitle: Text,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 12) {
                message
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: action) {
                    actionTitle
                }
                .buttonStyle(PomoGemCompactButtonStyle())
                .accessibilityIdentifier(identifier)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedSource: FocusMusicSource? {
        FocusMusicCatalog.source(id: chosenSourceID)
    }

    /// The generic "play music" offer. No `itemID`: Apple documents it for
    /// a music item, and an editorial playlist ID is not known to load.
    private var offerOptions: MusicSubscriptionOffer.Options {
        var options = MusicSubscriptionOffer.Options()
        options.messageIdentifier = .playMusic
        return options
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
