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
    /// Leaving PomoGem mid-focus pauses the timer while the leave pause is on
    /// (F1, Docs/FocusLeavePause.md), so the Settings button is replaced by a
    /// line saying where to change the permission after the focus. The focus
    /// screen passes a focus start for its own breaks too, so they have no
    /// button either; Home breaks (BreakTimerView) and Settings run no focus,
    /// so they keep the button.
    let allowsLeavingApp: Bool
    let subjects: [FocusMusicSubject]
    /// An activity editor keeps this choice in its draft until Save. Picking
    /// here must not play, write preferences, or add a favorite.
    let sourceSelection: Binding<FocusMusicSource?>?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(FocusMusicPreferences.shuffleKey) private var shuffle = FocusMusicPreferences.defaultShuffle
    @State private var isOfferPresented = false
    @State private var selectedSubjectID: UUID?
    @State private var isDiscoveryExpanded = false
    @State private var addsMusicByLink = false
    @State private var searchTerm = ""
    @State private var searchResults: [FocusMusicSource] = []
    @State private var isSearching = false
    @State private var didSearch = false
    @State private var searchError: FocusMusicDiscoveryFailure?
    @State private var sourceLink = ""
    @State private var sourceName = ""
    @State private var linkError: String?
    @State private var librarySources: [FocusMusicSource] = []
    @State private var isLoadingLibrary = false
    @State private var didLoadLibrary = false
    @State private var libraryError: FocusMusicDiscoveryFailure?
    @State private var libraryTask: Task<Void, Never>?

    init(
        controller: FocusMusicController,
        allowsLeavingApp: Bool,
        subjects: [FocusMusicSubject] = [],
        initialSubjectID: UUID? = nil,
        sourceSelection: Binding<FocusMusicSource?>? = nil
    ) {
        self.controller = controller
        self.allowsLeavingApp = allowsLeavingApp
        self.subjects = subjects
        self.sourceSelection = sourceSelection
        _selectedSubjectID = State(initialValue: subjects.contains { $0.id == initialSubjectID } ? initialSubjectID : nil)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !subjects.isEmpty { subjectPicker }
                    introduction
                    if sourceSelection == nil { status }
                    if sourceSelection == nil, let hint = controller.hint {
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
                    musicDiscovery
                    libraryPlaylists
                    sourceList
                    if sourceSelection != nil { status }
                    if sourceSelection == nil {
                        shuffleToggle
                        autoplayToggle
                    }
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
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await controller.refresh(forceSubscriptionCheck: true)
                await controller.loadCatalogTitlesIfNeeded()
            }
        }
        .onChange(of: controller.authorization) { _, authorization in
            searchError = searchError?.remaining(after: authorization)
            libraryError = libraryError?.remaining(after: authorization)
        }
        .onDisappear {
            libraryTask?.cancel()
            libraryTask = nil
        }
        .onChange(of: subjects) { _, updated in
            if let selectedSubjectID, !updated.contains(where: { $0.id == selectedSubjectID }) {
                self.selectedSubjectID = nil
            }
        }
    }

    // MARK: - Sections

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 6) {
            if sourceSelection != nil {
                Text("音楽は取り組みの「保存」で確定します。", tableName: "Focus", comment: "Activity editor music picker: choosing is a draft, saved only with the activity")
                    .font(.subheadline)
            }
            Text("ミュージックアプリで再生します。配信曲にはApple Musicの登録が必要です。", tableName: "Focus")
                .font(.subheadline)
            if sourceSelection == nil {
                Text("再生すると、ミュージックアプリの再生中のリストが入れ替わります。タイマーが終わっても音楽は止まりません。", tableName: "Focus")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var subjectPicker: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 10) {
                Picker(
                    String(localized: "音楽の設定先", table: "Focus"),
                    selection: $selectedSubjectID
                ) {
                    Text("共通の音楽", tableName: "Focus").tag(UUID?.none)
                    ForEach(subjects) { subject in
                        Text(verbatim: subject.name).tag(Optional(subject.id))
                    }
                }
                .pickerStyle(.menu)
                .tint(PomoGemTheme.amber)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("focus-music.subject")

                if let selectedSubjectID {
                    if controller.subjectSource(for: selectedSubjectID) != nil {
                        Button {
                            controller.clearSubjectSource(selectedSubjectID)
                        } label: {
                            Text("共通の音楽を使う", tableName: "Focus")
                        }
                        .buttonStyle(PomoGemCompactButtonStyle(isProminent: false))
                        .accessibilityIdentifier("focus-music.subject-reset")
                    } else {
                        Text("共通の音楽を使っています。下で選ぶと、この取り組みだけの音楽になります。", tableName: "Focus")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("取り組みごとの指定がないときに使う音楽です。", tableName: "Focus")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        if sourceSelection == nil, controller.showsNowPlaying {
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
                transportLayout {
                    Button {
                        Task { await controller.togglePlayback(subjectID: selectedSubjectID) }
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
                        controller.transportToggle(for: selectedSubjectID) == .unavailable
                            || (controller.isBusy && controller.transportToggle(for: selectedSubjectID) != .pause)
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
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
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

    private var transportLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    private var sourceList: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 8) {
                if let sourceSelection {
                    Button {
                        sourceSelection.wrappedValue = nil
                        dismiss()
                    } label: {
                        HStack {
                            Text("共通の音楽を使う", tableName: "Focus")
                            Spacer()
                            if sourceSelection.wrappedValue == nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("focus-music.use-common")
                    Divider()
                }
                if let chosen = selectedSource,
                   !controller.savedSources.contains(where: { $0.id == chosen.id }),
                   !FocusMusicCatalog.sources.contains(where: { $0.id == chosen.id }) {
                    Text("選択中", tableName: "Focus", comment: "VoiceOver value: this music is the chosen one")
                        .font(.headline)
                    sourceWithFavorite(chosen)
                    Divider()
                }
                if !controller.savedSources.isEmpty {
                    Text("お気に入り", tableName: "Focus")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(controller.savedSources) { source in
                        sourceWithFavorite(source)
                    }
                    if !curatedSources.isEmpty { Divider().padding(.vertical, 4) }
                }
                if !curatedSources.isEmpty {
                    Text("音楽を選ぶ", tableName: "Focus", comment: "Focus music list: its heading, and the timer button's VoiceOver action that opens it")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(curatedSources) { source in
                        sourceWithFavorite(source)
                    }
                }
            }
        }
    }

    private func sourceRow(_ source: FocusMusicSource, isSearchResult: Bool = false) -> some View {
        let isSelected = source.id == selectedSource?.id
        // D4.3: without a way to play (no permission, or no subscription and
        // no offer) a row only remembers the choice and shows no play mark.
        let allowsPlayback = sourceSelection == nil && controller.availability.allowsRowPlayback
        return Button {
            if let sourceSelection {
                sourceSelection.wrappedValue = source
                dismiss()
                return
            }
            Task {
                if await controller.choose(source, subjectID: selectedSubjectID) == .presentOffer {
                    isOfferPresented = true
                }
            }
        } label: {
            HStack(spacing: 12) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: sourceIcon(source))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.amber)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: controller.title(for: source))
                        .font(.system(.body, design: .rounded, weight: .bold))
                    Group {
                        switch source.kind {
                        case .playlist:
                            Text("プレイリスト", tableName: "Focus")
                        case .station:
                            Text("ステーション", tableName: "Focus", comment: "An Apple Music radio station")
                        case .song:
                            Text("曲", tableName: "Focus", comment: "One song in Apple Music")
                        case .album:
                            Text("アルバム", tableName: "Focus", comment: "An Apple Music album")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                }
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
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
        .disabled(sourceSelection == nil && controller.isBusy)
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
        .accessibilityIdentifier(isSearchResult ? "focus-music.result.\(source.id)" : "focus-music.source.\(source.id)")
    }

    @ViewBuilder
    private func sourceWithFavorite(_ source: FocusMusicSource, isSearchResult: Bool = false) -> some View {
        let isSaved = controller.savedSources.contains { $0.id == source.id }
        let title = controller.title(for: source)
        if sourceSelection != nil {
            sourceRow(source, isSearchResult: isSearchResult)
        } else {
        HStack(spacing: 4) {
            sourceRow(source, isSearchResult: isSearchResult)
            Button {
                if isSaved {
                    controller.removeSavedSource(source)
                } else {
                    controller.saveSource(source)
                }
            } label: {
                Image(systemName: isSaved ? "heart.fill" : "heart")
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PomoGemTheme.amber)
            .accessibilityLabel(
                isSaved
                    ? Text("「\(title)」をお気に入りから削除", tableName: "Focus", comment: "VoiceOver label; argument is the music title")
                    : Text("「\(title)」をお気に入りに追加", tableName: "Focus", comment: "VoiceOver label; argument is the music title")
            )
            .accessibilityIdentifier("focus-music.\(isSearchResult ? "result-favorite" : "favorite").\(source.id)")
        }
        .accessibilityElement(children: .contain)
        }
    }

    private var libraryPlaylists: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: loadLibraryPlaylists) {
                    Label {
                        Text("自分のプレイリストから選ぶ", tableName: "Focus", comment: "Load playlists from the person's Music library after an explicit tap")
                    } icon: {
                        Image(systemName: "music.note.list")
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .disabled(isLoadingLibrary)
                .accessibilityIdentifier("focus-music.library")
                if isLoadingLibrary { ProgressView() }
                if let libraryError {
                    Text(libraryError == .permissionRequired
                        ? String(localized: "プレイリストを選ぶには、Apple Musicへのアクセスを許可してください。", table: "Focus", comment: "Music library playlist picker requires permission")
                        : String(localized: "プレイリストを読み込めませんでした。もう一度お試しください。", table: "Focus", comment: "Music library playlist load failed"))
                        .foregroundStyle(PomoGemTheme.amber)
                        .accessibilityIdentifier("focus-music.library-error")
                } else if didLoadLibrary, librarySources.isEmpty {
                    Text("ミュージックのライブラリにプレイリストがありません。", tableName: "Focus", comment: "Library playlist picker empty state")
                        .foregroundStyle(PomoGemTheme.muted)
                }
                ForEach(librarySources) { source in
                    sourceWithFavorite(source)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var musicDiscovery: some View {
        PomoGemCard {
            DisclosureGroup(isExpanded: $isDiscoveryExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(
                        String(localized: "音楽の追加方法", table: "Focus"),
                        selection: $addsMusicByLink
                    ) {
                        Text("検索", tableName: "Focus", comment: "Search Apple Music to add a favorite").tag(false)
                        Text("リンク", tableName: "Focus", comment: "Paste an Apple Music link to add a favorite").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("focus-music.add-method")
                    if addsMusicByLink {
                        linkEntry
                    } else {
                        musicSearch
                    }
                }
                .padding(.top, 12)
            } label: {
                Label {
                    Text("音楽を探す", tableName: "Focus")
                        .font(.system(.body, design: .rounded, weight: .bold))
                } icon: {
                    if !dynamicTypeSize.isAccessibilitySize {
                        Image(systemName: "plus.circle")
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityIdentifier("focus-music.add-music")
            }
            .tint(PomoGemTheme.amber)
        }
    }

    private var musicSearch: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(
                String(localized: "音楽やアーティストの名前", table: "Focus"),
                text: $searchTerm
            )
            .textFieldStyle(.roundedBorder)
            .submitLabel(.search)
            .onSubmit { searchMusic() }
            .accessibilityIdentifier("focus-music.search-query")
            Button(action: searchMusic) {
                Label {
                    Text("Apple Musicで検索", tableName: "Focus")
                } icon: {
                    Image(systemName: "magnifyingglass")
                }
            }
            .buttonStyle(PomoGemCompactButtonStyle())
            .disabled(isSearching || searchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("focus-music.search")
            if isSearching {
                ProgressView {
                    Text("音楽を探しています", tableName: "Focus")
                }
            }
            if let searchError {
                Text(searchError == .permissionRequired
                    ? String(localized: "音楽を検索するには、Apple Musicへのアクセスを許可してください。", table: "Focus")
                    : String(localized: "検索できませんでした。通信を確認して、もう一度お試しください。", table: "Focus"))
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("focus-music.search-error")
            } else if didSearch, !isSearching, searchResults.isEmpty {
                Text("音楽が見つかりませんでした。別の名前で試してみてください。", tableName: "Focus")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(searchResults) { source in
                sourceWithFavorite(source, isSearchResult: true)
            }
        }
    }

    private var linkEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(
                String(localized: "Apple Musicの共有リンク", table: "Focus"),
                text: $sourceLink
            )
            .textFieldStyle(.roundedBorder)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("focus-music.link")
            TextField(
                String(localized: "表示名（任意）", table: "Focus"),
                text: $sourceName
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("focus-music.link-name")
            Button(action: addSourceLink) {
                if sourceSelection != nil {
                    Text("この音楽を選ぶ", tableName: "Focus", comment: "Use the pasted music link in the activity editor draft")
                } else {
                    Text("お気に入りに追加", tableName: "Focus")
                }
            }
            .buttonStyle(PomoGemCompactButtonStyle(isProminent: false))
            .disabled(sourceLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("focus-music.add-link")
            if let linkError {
                Text(verbatim: linkError)
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("focus-music.link-error")
            }
        }
    }

    private var shuffleToggle: some View {
        PomoGemCard {
            Toggle(isOn: $shuffle) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("シャッフルで再生する", tableName: "Focus")
                        .font(.system(.body, design: .rounded, weight: .bold))
                    Text("次にプレイリストやアルバムを再生するとき、曲順をランダムにします。ステーションの曲順はApple Musicが決めます。", tableName: "Focus")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(PomoGemTheme.amber)
            .accessibilityIdentifier("focus-music.shuffle")
        }
    }

    private var autoplayToggle: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { controller.isAutoplayEnabled(for: selectedSubjectID) },
                set: { controller.setAutoplayEnabled($0, for: selectedSubjectID) }
            )) {
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
            if let selectedSubjectID,
               controller.subjectAutoplayOverride(for: selectedSubjectID) != nil {
                Button {
                    controller.clearSubjectAutoplay(selectedSubjectID)
                } label: {
                    Text("共通の自動再生設定に戻す", tableName: "Focus", comment: "Restore the shared autoplay preference for this activity")
                }
                .accessibilityIdentifier("focus-music.autoplay-reset")
            }
            }
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
        if let sourceSelection { return sourceSelection.wrappedValue }
        return controller.chosenSource(for: selectedSubjectID)
    }

    private var curatedSources: [FocusMusicSource] {
        FocusMusicCatalog.sources.filter { source in
            !controller.savedSources.contains(where: { $0.id == source.id })
        }
    }

    private func sourceIcon(_ source: FocusMusicSource) -> String {
        switch source.kind {
        case .station: "dot.radiowaves.left.and.right"
        case .playlist: "music.note.list"
        case .song: "music.note"
        case .album: "square.stack"
        }
    }

    private func searchMusic() {
        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !isSearching else { return }
        isSearching = true
        // Only a successful empty response can say that nothing was found.
        // Clearing a recovered permission error must not create that claim.
        didSearch = false
        searchError = nil
        searchResults = []
        Task { @MainActor in
            defer { isSearching = false }
            do {
                searchResults = try await controller.search(term: term)
                didSearch = true
            } catch {
                searchError = FocusMusicDiscoveryFailure(error: error, authorization: controller.authorization)
                    .remaining(after: controller.authorization)
            }
        }
    }

    private func addSourceLink() {
        guard let source = FocusMusicSourceLink.parse(sourceLink) else {
            linkError = String(localized: "曲、アルバム、プレイリスト、ステーションのApple Music共有リンクを貼り付けてください。", table: "Focus")
            return
        }
        let name = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let namedSource = FocusMusicSource(
            id: source.id,
            fallbackTitle: name.isEmpty ? source.fallbackTitle : name,
            kind: source.kind,
            customTitle: name.isEmpty ? nil : name
        )
        if let sourceSelection {
            sourceSelection.wrappedValue = namedSource
            dismiss()
        } else {
            controller.saveSource(namedSource)
        }
        sourceLink = ""
        sourceName = ""
        linkError = nil
        isDiscoveryExpanded = false
    }

    private func loadLibraryPlaylists() {
        guard !isLoadingLibrary else { return }
        isLoadingLibrary = true
        libraryError = nil
        libraryTask = Task { @MainActor in
            defer { isLoadingLibrary = false }
            do {
                let sources = try await controller.libraryPlaylists()
                guard !Task.isCancelled else { return }
                librarySources = sources
                didLoadLibrary = true
            } catch {
                guard !Task.isCancelled else { return }
                libraryError = FocusMusicDiscoveryFailure(error: error, authorization: controller.authorization)
                    .remaining(after: controller.authorization)
            }
        }
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
