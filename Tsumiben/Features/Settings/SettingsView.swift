import SwiftData
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Query private var subjects: [Subject]
    @Query private var preferences: [Prefs]
    @Query private var activityResetMarkers: [ActivityResetMarker]

    @AppStorage("notifications.wrapped") private var wrappedNotifications = false
    @AppStorage(UsagePurpose.storageKey) private var usagePurposeRawValue = UsagePurpose.study.rawValue
    @State private var purchase = PurchaseManager.shared
    @State private var isSubjectEditorPresented = false
    @State private var editingSubjectID: UUID?
    @State private var subjectPendingDeletion: Subject?
    @State private var subjectPendingDeletionRecordCount: Int?
    @State private var showResetData = false
    @State private var showFontLicense = false
    @State private var notificationError: String?
    @State private var settingsError: String?
    @State private var dataExportTask: Task<Void, Never>?
    @State private var activeDataExportID: UUID?
    @State private var dataExportProgress: TsumibenDataExportProgress?
    @State private var dataExportFileURL: URL?
    @State private var isExportingData = false
    @State private var showDataExportShareSheet = false
    @State private var dataExportError: String?

    private var prefs: Prefs? {
        currentPreferences.first
    }
    private var currentPreferences: [Prefs] {
        preferences.filter {
            ActivityResetPolicy.isCurrent($0.activityEpochID, markers: resetSnapshots)
        }
    }
    private var resetSnapshots: [ActivityResetSnapshot] {
        activityResetMarkers.map(\.policySnapshot)
    }
    private func isCurrentActivity(_ epochID: UUID?) -> Bool {
        ActivityResetPolicy.isCurrent(epochID, markers: resetSnapshots)
    }

    init() {
        var subjectDescriptor = FetchDescriptor<Subject>(sortBy: [
            SortDescriptor(\Subject.sortOrder),
            SortDescriptor(\Subject.createdAt),
            SortDescriptor(\Subject.id)
        ])
        subjectDescriptor.fetchLimit = Constants.App.maximumSubjects + 4
        _subjects = Query(subjectDescriptor)

        var prefsDescriptor = FetchDescriptor<Prefs>(
            sortBy: [SortDescriptor(\Prefs.id)]
        )
        prefsDescriptor.fetchLimit = 16
        _preferences = Query(prefsDescriptor)

        var markerDescriptor = FetchDescriptor<ActivityResetMarker>(sortBy: [
            SortDescriptor(\ActivityResetMarker.resetAt, order: .reverse),
            SortDescriptor(\ActivityResetMarker.sequence, order: .reverse),
            SortDescriptor(\ActivityResetMarker.writerDeviceID, order: .reverse),
            SortDescriptor(\ActivityResetMarker.epochID, order: .reverse),
            SortDescriptor(\ActivityResetMarker.id, order: .reverse)
        ])
        markerDescriptor.fetchLimit = 1
        _activityResetMarkers = Query(markerDescriptor)
    }

    var body: some View {
        List {
            usageSection
            subjectsSection
            focusSection
            rarePebbleSection
            sensorySection
            CloudSyncSettingsSection()
            notificationSection
            shareSection
            proSection
            privacySection
            creditsSection
            dataSection
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .tsumibenNavigationTitle("設定")
        .toolbarTitleDisplayMode(.large)
        .sheet(isPresented: $isSubjectEditorPresented, onDismiss: {
            editingSubjectID = nil
        }) {
            if let editingSubjectID,
               let subject = subjects.first(where: { $0.id == editingSubjectID }) {
                SubjectEditorView(
                    subject: subject,
                    suggestedColorHex: subject.colorHex,
                    usagePurpose: usagePurpose
                ) { name, color, isArchived in
                    saveSubjectEdits(
                        subject: subject,
                        name: name,
                        color: color,
                        isArchived: isArchived
                    )
                }
            } else {
                SubjectEditorView(
                    subject: nil,
                    suggestedColorHex: nextSubjectColor,
                    usagePurpose: usagePurpose,
                    onSave: addSubject
                )
            }
        }
        .sheet(isPresented: $showFontLicense) {
            FontLicenseView()
        }
        .sheet(isPresented: $showDataExportShareSheet, onDismiss: {
            removePresentedDataExport()
        }) {
            if let dataExportFileURL {
                TsumibenDataExportShareSheet(fileURL: dataExportFileURL) { error in
                    if let error {
                        dataExportError = "書き出したファイルを共有できませんでした。\n\(error.localizedDescription)"
                    }
                    showDataExportShareSheet = false
                }
            }
        }
        .alert(
            "カテゴリを削除",
            isPresented: Binding(
                get: { subjectPendingDeletion != nil },
                set: {
                    if !$0 {
                        subjectPendingDeletion = nil
                        subjectPendingDeletionRecordCount = nil
                    }
                }
            ),
            presenting: subjectPendingDeletion
        ) { subject in
            Button("「\(subject.safeDisplayName)」を削除", role: .destructive) {
                subjectPendingDeletion = nil
                subjectPendingDeletionRecordCount = nil
                deleteSubject(subject)
            }
            Button("キャンセル", role: .cancel) {
                subjectPendingDeletion = nil
                subjectPendingDeletionRecordCount = nil
            }
        } message: { subject in
            Text(subjectDeletionMessage(
                for: subject,
                recordCount: subjectPendingDeletionRecordCount ?? 0
            ))
        }
        .alert("表示中の記録をリセット", isPresented: $showResetData) {
            Button("キャンセル", role: .cancel) {}
            Button("リセット", role: .destructive) { resetStudyData() }
        } message: {
            Text("集中の粒・まとまり粒・記念石を表示と集計から外し、0から始めます。同じiCloudの端末には接続後に反映されます。オフライン端末から古い記録が戻ることを防ぐため、旧世代の行は同期用に残り、データ書き出しには含まれます。物理的な消去はAppleのiCloudデータ管理から行ってください。この操作は取り消せません。")
        }
        .alert("通知を設定できませんでした", isPresented: Binding(
            get: { notificationError != nil },
            set: { if !$0 { notificationError = nil } }
        )) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(notificationError ?? "")
        }
        .alert("設定を完了できませんでした", isPresented: Binding(
            get: { settingsError != nil },
            set: { if !$0 { settingsError = nil } }
        )) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(settingsError ?? "")
        }
        .alert("データを書き出せませんでした", isPresented: Binding(
            get: { dataExportError != nil },
            set: { if !$0 { dataExportError = nil } }
        )) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(dataExportError ?? "")
        }
        .task {
            await purchase.refreshEntitlements()
            await reconcileNotificationAuthorization()
            await removeStaleDataExports()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await purchase.refreshEntitlements()
                await reconcileNotificationAuthorization()
            }
        }
        .onDisappear {
            guard !showDataExportShareSheet else { return }
            cancelDataExport(announce: false)
            removePresentedDataExport()
        }
    }

    private var usagePurpose: UsagePurpose {
        UsagePurpose(rawValue: usagePurposeRawValue) ?? .study
    }

    private var rareRewardMode: RareRewardMode {
        RareRewardMode.resolved(preferences: currentPreferences)
    }

    private var hasExplicitRareRewardSelection: Bool {
        RareRewardMode.hasExplicitSelection(preferences: currentPreferences)
    }

    private var rareRewardModeBinding: Binding<RareRewardMode> {
        Binding(
            get: { rareRewardMode },
            set: { updateRareRewardMode($0) }
        )
    }

    private var availableSubjectSlots: Int {
        max(0, Constants.App.maximumSubjects - subjects.count)
    }

    private var missingWorkPresets: [UsagePurpose.CategoryPreset] {
        guard usagePurpose == .work else { return [] }
        let existingKeys = Set(subjects.map {
            SubjectNamePolicy.comparisonKey($0.name)
        })
        return UsagePurpose.work.presets.filter {
            !existingKeys.contains(SubjectNamePolicy.comparisonKey($0.name))
        }
    }

    private var usagePurposeBinding: Binding<UsagePurpose> {
        Binding(
            get: { usagePurpose },
            set: { updateUsagePurpose($0) }
        )
    }

    private func updateUsagePurpose(_ purpose: UsagePurpose) {
        guard purpose != usagePurpose else { return }
        let previousRawValue = usagePurposeRawValue
        usagePurposeRawValue = purpose.rawValue

        guard let prefs else {
            usagePurposeRawValue = previousRawValue
            settingsError = "使い方をiCloudへ保存できませんでした。しばらく待ってから、もう一度お試しください。"
            return
        }

        prefs.usagePurposeRawValue = purpose.rawValue
        prefs.usagePurposeUpdatedAt = .now
        if purpose == .work {
            // A prior opt-in made while studying must not carry into a newly
            // selected professional context without another explicit choice.
            prefs.showsThemeNameExternally = false
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            usagePurposeRawValue = previousRawValue
            settingsError = "使い方をiCloudへ保存できませんでした。変更前の状態に戻しました。\n\(error.localizedDescription)"
        }
    }

    private func updateRareRewardMode(_ mode: RareRewardMode) {
        guard mode != rareRewardMode || !hasExplicitRareRewardSelection else { return }
        guard !currentPreferences.isEmpty else {
            settingsError = "ランダムなレア粒の設定をiCloudへ保存できませんでした。しばらく待ってから、もう一度お試しください。"
            return
        }

        let changedAt = Date.now
        for preference in currentPreferences {
            preference.rareRewardModeRawValue = mode.rawValue
            preference.rareRewardModeUpdatedAt = changedAt
        }
        if let error = commitChanges(failureMessage: "ランダムなレア粒の設定を保存できませんでした。") {
            settingsError = error
        }
    }

    private var usageSection: some View {
        Section {
            Picker("主な用途", selection: usagePurposeBinding) {
                ForEach(UsagePurpose.allCases) { purpose in
                    Label(purpose.title, systemImage: purpose.symbol)
                        .tag(purpose)
                }
            }
            .pickerStyle(.segmented)

            if let privacyGuidance = usagePurpose.privacyGuidance {
                SettingLabel(
                    title: "仕事では大分類で記録",
                    subtitle: privacyGuidance,
                    symbol: "lock.shield.fill"
                )
                if let professionalUseGuidance = usagePurpose.professionalUseGuidance {
                    SettingLabel(
                        title: "個人の振り返り用",
                        subtitle: professionalUseGuidance,
                        symbol: "person.crop.circle.badge.checkmark"
                    )
                }
                if !missingWorkPresets.isEmpty {
                    Menu {
                        ForEach(missingWorkPresets) { preset in
                            Button {
                                addWorkPreset(preset)
                            } label: {
                                Label(preset.name, systemImage: "plus.circle")
                            }
                            .disabled(availableSubjectSlots == 0)
                        }
                    } label: {
                        SettingLabel(
                            title: "仕事カテゴリ候補を追加",
                            subtitle: availableSubjectSlots > 0
                                ? "企画・開発などから選択（あと\(availableSubjectSlots)件）"
                                : "最大\(Constants.App.maximumSubjects)件です。不要なカテゴリを整理すると追加できます",
                            symbol: "briefcase.fill"
                        )
                    }
                    .accessibilityHint("追加する仕事カテゴリを選びます")
                }
            } else {
                SettingLabel(
                    title: "勉強と資格に合わせる",
                    subtitle: "教科名・資格名ごとに集中を積みます",
                    symbol: "book.closed.fill"
                )
            }
        } header: {
            Text("使い方")
        } footer: {
            Text("用途を変えても、現在のカテゴリや過去の記録は変わりません。\(usagePurpose.customExamples)")
        }
    }

    private var subjectsSection: some View {
        Section {
            ForEach(Array(subjects.enumerated()), id: \.element.id) { index, subject in
                Button {
                    editingSubjectID = subject.id
                    isSubjectEditorPresented = true
                } label: {
                    HStack(spacing: 13) {
                        ZStack {
                            Circle().fill(Color(hex: subject.colorHex)).frame(width: 15, height: 15)
                            if subject.isArchived {
                                Circle().stroke(.white.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 21, height: 21)
                            }
                        }
                        Text(subject.safeDisplayName)
                            .foregroundStyle(subject.isArchived ? TsumibenTheme.muted : TsumibenTheme.text)
                        Spacer()
                        if subject.isArchived {
                            Text("非表示").font(.caption).foregroundStyle(TsumibenTheme.muted)
                        }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(TsumibenTheme.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TsumibenRowButtonStyle())
                .accessibilityHint(
                    subjects.count > 1
                        ? "ダブルタップで編集。アクションで順番を変更できます"
                        : "ダブルタップで編集できます"
                )
                .modifier(
                    SubjectReorderAccessibilityModifier(
                        index: index,
                        count: subjects.count,
                        moveUp: { moveSubject(at: index, direction: .up) },
                        moveDown: { moveSubject(at: index, direction: .down) }
                    )
                )
                .swipeActions(edge: .leading) {
                    Button(subject.isArchived ? "表示" : "非表示") {
                        subject.isArchived.toggle()
                        if let error = commitChanges(
                            failureMessage: "カテゴリの表示設定を保存できませんでした。"
                        ) {
                            settingsError = error
                        }
                    }
                    .tint(TsumibenTheme.raised)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("削除", role: .destructive) {
                        prepareSubjectDeletion(subject)
                    }
                }
            }
            .onMove(perform: moveSubjects)

            Button {
                editingSubjectID = nil
                isSubjectEditorPresented = true
            } label: {
                Label("\(usagePurpose.categoryTitle)を追加", systemImage: "plus")
            }
            .disabled(subjects.count >= Constants.App.maximumSubjects)
            .accessibilityHint(
                subjects.count >= Constants.App.maximumSubjects
                    ? "最大12件です。不要な項目を削除すると追加できます"
                    : "新しい\(usagePurpose.categoryTitle)を追加します"
            )
        } header: {
            Text(usagePurpose.categoryTitle)
        } footer: {
            Text("最大12件。削除しても、過去の質量と記録は残ります。長押しで順番を変更できます。")
        }
    }

    private var focusSection: some View {
        Section("集中") {
            if let prefs {
                @Bindable var prefs = prefs
                Toggle(isOn: settingBinding(
                    $prefs.keepScreenAwake,
                    target: prefs,
                    keyPath: \.keepScreenAwake
                )) {
                    SettingLabel(
                        title: "集中中は画面をロックしない",
                        subtitle: "集中画面を開いている間だけ有効",
                        symbol: "sun.max"
                    )
                }
                .accessibilityIdentifier("settings.keep-screen-awake")
                Toggle(isOn: settingBinding(
                    $prefs.showsThemeNameExternally,
                    target: prefs,
                    keyPath: \.showsThemeNameExternally
                )) {
                    SettingLabel(
                        title: "ロック画面・通知にテーマ名を表示",
                        subtitle: "オフなら「集中」とだけ表示します",
                        symbol: "lock.rectangle.stack"
                    )
                }
            }
            if purchase.isPro {
                if prefs != nil {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 8) {
                                SettingLabel(title: "任意のタイマー時間", subtitle: "1〜180分", symbol: "timer")
                                proAvailabilityLabel
                                    .padding(.leading, 40)
                            }
                        } else {
                            HStack(spacing: 10) {
                                SettingLabel(title: "任意のタイマー時間", subtitle: "1〜180分", symbol: "timer")
                                Spacer(minLength: 8)
                                proAvailabilityLabel
                            }
                        }
                    }
                    .frame(minHeight: 44)

                    Picker("既定の集中時間", selection: preferredFocusMinutesBinding) {
                        ForEach(
                            Constants.Timer.customMinimumMinutes ... Constants.Timer.customMaximumMinutes,
                            id: \.self
                        ) { minutes in
                            Text("\(minutes)分").tag(minutes)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .frame(minHeight: 44)
                }
            } else {
                Button {
                    router.presentPaywall(from: .customTimer)
                } label: {
                    HStack(spacing: 10) {
                        SettingLabel(title: "任意のタイマー時間", subtitle: "1〜180分", symbol: "timer")
                        Spacer(minLength: 8)
                        Text("Pro")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(TsumibenTheme.amber)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                    }
                    .frame(minHeight: 44)
                }
                .buttonStyle(TsumibenBareButtonStyle())
                .accessibilityIdentifier("settings.custom-timer")
                .accessibilityHint("つみべんProのプランを表示します")
            }
        }
    }

    private var sensorySection: some View {
        Section("音と触覚") {
            if let prefs {
                @Bindable var prefs = prefs
                Toggle(isOn: settingBinding(
                    $prefs.soundOn,
                    target: prefs,
                    keyPath: \.soundOn
                )) {
                    SettingLabel(title: "音", subtitle: "サイレントスイッチに従います", symbol: "speaker.wave.2")
                }
                Toggle(isOn: settingBinding(
                    $prefs.hapticsOn,
                    target: prefs,
                    keyPath: \.hapticsOn
                )) {
                    SettingLabel(
                        title: "触覚",
                        subtitle: "完了・着地・瓶操作。レア専用は標準モードのみ",
                        symbol: "waveform"
                    )
                }
            }
        }
    }

    private var rarePebbleSection: some View {
        Section {
            Text("粒のバリエーション")
                .font(.headline.weight(.black))
                .foregroundStyle(Color.white)
                .textCase(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black)
                .accessibilityAddTraits(.isHeader)
                .listRowBackground(Color.black)
                .listRowSeparator(.hidden)

            Picker(selection: rareRewardModeBinding) {
                ForEach(RareRewardMode.choiceOrder) { mode in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.title)
                        Text(mode.settingsDescription)
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                    }
                    .tag(mode)
                }
            } label: {
                SettingLabel(
                    title: "ランダムなレア粒",
                    subtitle: hasExplicitRareRewardSelection
                        ? rareRewardMode.settingsDescription
                        : "未選択のため抽選しません。最初の実測タイマー前にも選べます",
                    symbol: rareRewardMode.systemImage
                )
            }
            .pickerStyle(.navigationLink)
            .disabled(prefs == nil)
            .accessibilityIdentifier("settings.rare-reward-mode")
            .accessibilityHint("質量、融合、結晶、成果、機能は変わりません。オフでは抽選用の端数と金の保証カウントを停止します")

            if !hasExplicitRareRewardSelection {
                Button {
                    updateRareRewardMode(.off)
                } label: {
                    Label("「抽選しない」を選択として保存", systemImage: "checkmark.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(TsumibenBareButtonStyle())
                .foregroundStyle(TsumibenTheme.amber)
                .disabled(prefs == nil)
                .accessibilityHint("乱数、抽選用の端数、金の保証カウントを動かさない選択をiCloudへ保存します")
                .accessibilityIdentifier("settings.rare-reward-confirm-off")
            }

            RarePebbleGuideRow(
                kind: .normal,
                title: "いつもの粒",
                detail: "全モードで同じ質量・結晶進捗"
            )
            RarePebbleGuideRow(
                kind: .gold,
                title: "金の粒",
                detail: rareRewardMode == .off
                    ? "オフ中は新しく抽選しません"
                    : "自然抽選 \(GachaEngine.probabilityLabel(for: .gold))。\(Constants.Gacha.pityMissCount)回続けて出なければ、次の抽選で保証"
            )
            RarePebbleGuideRow(
                kind: .prism,
                title: "虹の粒",
                detail: rareRewardMode == .off
                    ? "オフ中は新しく抽選しません"
                    : "自然抽選 \(GachaEngine.probabilityLabel(for: .prism))"
            )
        } footer: {
            Text(
                "自然確率は、いつもの粒 \(GachaEngine.probabilityLabel(for: .normal))、金 \(GachaEngine.probabilityLabel(for: .gold))、虹 \(GachaEngine.probabilityLabel(for: .prism))。標準と控えめでは、実測タイマーで250g積むごとに1回抽選し、250g未満の端数は次回へ繰り越します。10分を6回、25分を2回と10分を1回、60分を1回はいずれも600gなので、抽選2回と100gの端数で同じです。\(GachaEngine.goldGuaranteeDisclosure) 控えめは種類を履歴に残しますが、追加の発光・専用音・専用触覚を使いません。抽選しない間は乱数を使わず、その間の質量を抽選用に貯めません。既存の端数と金の保証は同じ位置で停止し、標準または控えめに戻すとそこから再開します。どのモードでも質量・融合・結晶・成果・機能は同じで、既に獲得した金・虹、記録、シェアも変わりません。端末の「視差効果を減らす」は抽選を止めず、動きだけを抑えます。"
            )
        }
    }

    private var notificationSection: some View {
        Section {
            if let prefs {
                Toggle(isOn: Binding(
                    get: { prefs.reminderEnabled },
                    set: { enabled in updateReminder(enabled: enabled) }
                )) {
                    SettingLabel(title: "毎日のリマインダ", subtitle: Constants.UIStrings.eveningNotification, symbol: "bell")
                }

                if prefs.reminderEnabled {
                    DatePicker(
                        "通知する時刻",
                        selection: reminderTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                }

                Toggle(isOn: Binding(
                    get: { wrappedNotifications },
                    set: { enabled in updateWrappedNotification(enabled: enabled) }
                )) {
                    SettingLabel(title: "今月の積み重ね", subtitle: "毎月1日に一度だけ", symbol: "circle.grid.3x3.fill")
                }
            }
        } header: {
            Text("通知")
        } footer: {
            Text("既定はオフ。赤いバッジや連続記録の警告は使いません。")
        }
    }

    private var shareSection: some View {
        Section("シェア") {
            if let prefs {
                @Bindable var prefs = prefs
                Toggle(isOn: settingBinding(
                    $prefs.shareIncludesManual,
                    target: prefs,
                    keyPath: \.shareIncludesManual
                )) {
                    SettingLabel(title: "自己申告を含める", subtitle: "既定は実測のみ", symbol: "square.and.arrow.up")
                }
            }
        }
    }

    private var proSection: some View {
        Section {
            Button {
                router.presentPaywall(from: .settings)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: purchase.isPro ? "checkmark.seal.fill" : "sparkles")
                        .foregroundStyle(TsumibenTheme.amber)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Constants.UIStrings.paywallTitle).font(.headline)
                        Text(purchase.isPro ? "利用中" : "任意時間・月の刻印・右下の小さな透かしを非表示")
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(TsumibenTheme.muted)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(TsumibenBareButtonStyle())
        }
    }

    private var privacySection: some View {
        Section("サポートとプライバシー") {
            SettingLabel(title: "自動収集なし", subtitle: "解析SDK・広告・自前サーバーなし", symbol: "hand.raised.fill")
            SettingLabel(title: "iCloud", subtitle: "あなたのプライベートデータベースのみ", symbol: "icloud")
            Link(destination: AppLinks.support) {
                SettingLabel(title: "サポート・お問い合わせ", subtitle: "Webで開く", symbol: "questionmark.circle")
            }
            Link(destination: AppLinks.privacyPolicy) {
                SettingLabel(title: "プライバシーポリシー", subtitle: "Webで開く", symbol: "doc.text")
            }
        }
    }

    private var creditsSection: some View {
        Section("クレジット") {
            LabeledContent("バージョン", value: appVersionLabel)
            LabeledContent("見出し書体", value: "Zen Maru Gothic")
            Button("SIL Open Font License 1.1を読む") {
                showFontLicense = true
            }
        }
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String

        guard let build, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }

    private var dataSection: some View {
        Section {
            Button(action: startDataExport) {
                HStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(TsumibenTheme.specular)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("データを書き出す")
                            .font(.headline)
                        Text(isExportingData ? "JSONファイルを作成中" : "全記録をJSONで保存・共有")
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                    }
                    Spacer()
                    if isExportingData {
                        ProgressView()
                            .tint(TsumibenTheme.specular)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                    }
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(TsumibenBareButtonStyle())
            .disabled(isExportingData)
            .accessibilityLabel("データを書き出す")
            .accessibilityHint("この端末で利用可能な記録、カテゴリ、設定をJSONファイルにして、保存先を選びます")

            if isExportingData, let dataExportProgress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: dataExportProgress.fractionCompleted)
                        .tint(TsumibenTheme.specular)
                    Text(dataExportProgress.accessibilityDescription)
                        .font(.caption)
                        .foregroundStyle(TsumibenTheme.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(dataExportProgress.accessibilityDescription)

                Button("書き出しをキャンセル", role: .cancel) {
                    cancelDataExport(announce: true)
                }
            }

            Button("表示中の記録をリセット", role: .destructive) { showResetData = true }
        } header: {
            Text("データ")
        } footer: {
            Text("書き出しファイルには、カテゴリ名・成果メモ・設定・同期用のランダムな端末識別子と、以前リセットした旧世代を含む、この端末で利用可能な全11種類の保存データが入ります。SNS用の共有画像とは異なります。保存先を確認してください。リセット後もカテゴリとアプリ設定は残ります。")
        }
    }

    private func startDataExport() {
        guard !isExportingData else { return }
        do {
            if modelContext.hasChanges {
                try modelContext.save()
            }
        } catch {
            dataExportError = "保存中の変更を確定できませんでした。\n\(error.localizedDescription)"
            return
        }

        removePresentedDataExport()
        let exportID = UUID()
        let worker = TsumibenDataExportWorker(modelContainer: modelContext.container)
        let appInfo = TsumibenDataExportAppInfo(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        )
        activeDataExportID = exportID
        isExportingData = true
        dataExportProgress = TsumibenDataExportProgress(
            phase: .preparing,
            completedRecords: 0,
            estimatedTotalRecords: 0
        )

        dataExportTask = Task { @MainActor in
            do {
                let result = try await worker.export(appInfo: appInfo) { progress in
                    Task { @MainActor in
                        guard activeDataExportID == exportID else { return }
                        dataExportProgress = progress
                    }
                }
                guard activeDataExportID == exportID, !Task.isCancelled else {
                    try? TsumibenDataExporter.removeExport(at: result.fileURL)
                    return
                }
                dataExportFileURL = result.fileURL
                showDataExportShareSheet = true
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "\(result.recordCounts.total)件のデータを書き出しました。保存先を選んでください"
                )
            } catch is CancellationError {
                // The explicit cancel control announces immediately. Navigating
                // away cancels silently so VoiceOver is not interrupted.
            } catch {
                guard activeDataExportID == exportID else { return }
                dataExportError = "データを書き出せませんでした。\n\(error.localizedDescription)"
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "データを書き出せませんでした"
                )
            }

            guard activeDataExportID == exportID else { return }
            activeDataExportID = nil
            dataExportTask = nil
            isExportingData = false
            dataExportProgress = nil
        }
    }

    private func cancelDataExport(announce: Bool) {
        guard isExportingData else { return }
        activeDataExportID = nil
        dataExportTask?.cancel()
        dataExportTask = nil
        dataExportProgress = nil
        isExportingData = false
        if announce {
            UIAccessibility.post(notification: .announcement, argument: "データの書き出しをキャンセルしました")
        }
    }

    private func removePresentedDataExport() {
        guard let url = dataExportFileURL else { return }
        dataExportFileURL = nil
        Task.detached(priority: .utility) {
            try? TsumibenDataExporter.removeExport(at: url)
        }
    }

    private func removeStaleDataExports() async {
        _ = await Task.detached(priority: .utility) {
            try? TsumibenDataExporter.removeStaleTemporaryExports()
        }.value
    }

    private func settingBinding(
        _ source: Binding<Bool>,
        target: Prefs,
        keyPath: ReferenceWritableKeyPath<Prefs, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { source.wrappedValue },
            set: { value in
                guard source.wrappedValue != value else { return }
                // Mutate through Bindable's projected binding so SwiftUI's
                // control state and accessibility value update in the same
                // transaction as the user's tap. The exact model remains the
                // persistence target below.
                source.wrappedValue = value
                updateSetting(target, keyPath, value: value)
            }
        )
    }

    private var preferredFocusMinutesBinding: Binding<Int> {
        Binding(
            get: {
                min(
                    max(
                        prefs?.preferredFocusMinutes ?? Constants.Timer.twentyFiveMinutes,
                        Constants.Timer.customMinimumMinutes
                    ),
                    Constants.Timer.customMaximumMinutes
                )
            },
            set: { minutes in
                updatePreferredFocusMinutes(minutes)
            }
        )
    }

    private var proAvailabilityLabel: some View {
        Text("利用可能")
            .font(.caption.weight(.bold))
            .foregroundStyle(TsumibenTheme.amber)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
                components.hour = prefs?.reminderHour ?? 20
                components.minute = prefs?.reminderMinute ?? 0
                return Calendar.current.date(from: components) ?? .now
            },
            set: { date in
                guard let prefs else { return }
                prefs.reminderHour = Calendar.current.component(.hour, from: date)
                prefs.reminderMinute = Calendar.current.component(.minute, from: date)
                if let error = commitChanges(failureMessage: "通知時刻を保存できませんでした。") {
                    settingsError = error
                    return
                }
                synchronizeNotifications()
            }
        )
    }

    private var nextSubjectColor: String {
        let hue = Double(subjects.count % Constants.App.maximumSubjects)
            / Double(Constants.App.maximumSubjects)
        return UIColor(
            hue: hue,
            saturation: Constants.App.subjectColorSaturation,
            brightness: Constants.App.subjectColorBrightness,
            alpha: 1
        ).hexString
    }

    private func addSubject(name: String, colorHex: String, isArchived _: Bool) -> String? {
        guard subjects.count < Constants.App.maximumSubjects else {
            return "カテゴリは最大\(Constants.App.maximumSubjects)件までです。"
        }
        if let validationError = subjectNameValidationError(name) {
            return validationError
        }
        guard let sanitizedName = SubjectNamePolicy.validated(name) else {
            return SubjectNamePolicy.validationError(for: name)?.message
                ?? "カテゴリ名を入力してください。"
        }
        modelContext.insert(
            Subject(
                name: sanitizedName,
                colorHex: colorHex,
                sortOrder: (subjects.map(\.sortOrder).max() ?? -1) + 1
            )
        )
        return commitChanges(failureMessage: "カテゴリを追加できませんでした。")
    }

    private func saveSubjectEdits(
        subject: Subject,
        name: String,
        color: String,
        isArchived: Bool
    ) -> String? {
        if let validationError = subjectNameValidationError(
            name,
            excluding: subject
        ) {
            return validationError
        }
        guard let sanitizedName = SubjectNamePolicy.validated(name) else {
            return SubjectNamePolicy.validationError(for: name)?.message
                ?? "カテゴリ名を入力してください。"
        }
        do {
            let related = try currentRelatedRecords(for: subject)
            subject.name = sanitizedName
            subject.colorHex = color
            subject.isArchived = isArchived
            for session in related.sessions {
                session.subjectNameSnapshot = sanitizedName
                session.subjectColorHexSnapshot = color
            }
            for stone in related.achievements {
                stone.subjectNameSnapshot = sanitizedName
                stone.subjectColorHexSnapshot = color
            }
            try modelContext.save()
            return nil
        } catch {
            modelContext.rollback()
            return "カテゴリの変更を保存できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
        }
    }

    private func addWorkPreset(_ preset: UsagePurpose.CategoryPreset) {
        if let error = addSubject(
            name: preset.name,
            colorHex: preset.colorHex,
            isArchived: false
        ) {
            settingsError = error
            return
        }
        router.showToast("「\(preset.name)」を追加しました", symbol: "briefcase.fill")
    }

    private func subjectNameValidationError(
        _ name: String,
        excluding editedSubject: Subject? = nil
    ) -> String? {
        if let validationError = SubjectNamePolicy.validationError(for: name) {
            return validationError.message
        }
        let normalized = SubjectNamePolicy.comparisonKey(name)
        let duplicate = subjects.first {
            $0.id != editedSubject?.id
                && SubjectNamePolicy.comparisonKey($0.name) == normalized
        }
        guard let duplicate else { return nil }
        return "同じ名前のカテゴリ「\(duplicate.safeDisplayName)」がすでにあります。"
    }

    private func deleteSubject(_ subject: Subject) {
        do {
            let related = try currentRelatedRecords(for: subject)
            for session in related.sessions {
                session.subjectNameSnapshot = subject.safeDisplayName
                session.subjectColorHexSnapshot = subject.colorHex
                session.subject = nil
            }
            for stone in related.achievements {
                stone.subjectNameSnapshot = subject.safeDisplayName
                stone.subjectColorHexSnapshot = subject.colorHex
                stone.subject = nil
            }
            modelContext.delete(subject)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            settingsError = "カテゴリを削除できませんでした。\n変更前の状態に戻しました。\n\(error.localizedDescription)"
        }
    }

    private func subjectDeletionMessage(
        for subject: Subject,
        recordCount: Int
    ) -> String {
        if recordCount == 0 {
            return "「\(subject.safeDisplayName)」を削除します。関連する過去の記録はありません。この操作は取り消せません。"
        }
        return "「\(subject.safeDisplayName)」だけを削除します。過去の記録\(recordCount)件と質量は消えず、現在の名前と色も残ります。この操作は取り消せません。"
    }

    private func prepareSubjectDeletion(_ subject: Subject) {
        do {
            let related = try currentRelatedRecords(for: subject)
            subjectPendingDeletionRecordCount = Set(related.sessions.map(\.id)).count
                + Set(related.achievements.map(\.id)).count
            subjectPendingDeletion = subject
        } catch {
            modelContext.rollback()
            settingsError = "関連する記録を確認できないため、カテゴリを削除できません。\n\(error.localizedDescription)"
        }
    }

    private func currentRelatedRecords(
        for subject: Subject
    ) throws -> (sessions: [StudySession], achievements: [AchievementStone]) {
        let targetID = subject.id
        let currentEpochID = ActivityResetPolicy.currentEpochID(from: resetSnapshots)
        let sessionDescriptor: FetchDescriptor<StudySession>
        let achievementDescriptor: FetchDescriptor<AchievementStone>
        if let currentEpochID {
            sessionDescriptor = FetchDescriptor(predicate: #Predicate {
                $0.dataEpochID == currentEpochID && $0.subject?.id == targetID
            })
            achievementDescriptor = FetchDescriptor(predicate: #Predicate {
                $0.dataEpochID == currentEpochID && $0.subject?.id == targetID
            })
        } else {
            sessionDescriptor = FetchDescriptor(predicate: #Predicate {
                $0.dataEpochID == nil && $0.subject?.id == targetID
            })
            achievementDescriptor = FetchDescriptor(predicate: #Predicate {
                $0.dataEpochID == nil && $0.subject?.id == targetID
            })
        }

        // A duplicate Subject row can share the same logical UUID after an
        // offline merge. Only mutate rows related to the exact object the user
        // selected; the UUID predicate keeps the database-side read scoped.
        let sessions = try modelContext.fetch(sessionDescriptor).filter {
            $0.subject === subject
        }
        let achievementCandidates = try modelContext.fetch(achievementDescriptor).filter {
            $0.subject === subject
        }
        let achievements = try AchievementStonePolicy.resolvedVisibleCandidates(
            from: achievementCandidates,
            context: modelContext
        ).filter { $0.subject === subject }
        return (sessions, achievements)
    }

    private func moveSubjects(from source: IndexSet, to destination: Int) {
        var reordered = subjects
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, subject) in reordered.enumerated() { subject.sortOrder = index }
        if let error = commitChanges(failureMessage: "カテゴリの並び順を保存できませんでした。") {
            settingsError = error
        }
    }

    private enum SubjectMoveDirection {
        case up
        case down
    }

    private func moveSubject(at index: Int, direction: SubjectMoveDirection) {
        guard subjects.indices.contains(index) else { return }
        switch direction {
        case .up:
            guard index > subjects.startIndex else { return }
            moveSubjects(from: IndexSet(integer: index), to: index - 1)
        case .down:
            guard index < subjects.index(before: subjects.endIndex) else { return }
            // `move(fromOffsets:toOffset:)` interprets the destination before
            // removing the source, hence +2 moves one visible row downward.
            moveSubjects(from: IndexSet(integer: index), to: index + 2)
        }
    }

    private func updatePreferredFocusMinutes(_ minutes: Int) {
        guard let prefs else { return }
        let normalized = min(
            max(minutes, Constants.Timer.customMinimumMinutes),
            Constants.Timer.customMaximumMinutes
        )
        guard prefs.preferredFocusMinutes != normalized else { return }
        prefs.preferredFocusMinutes = normalized
        if let error = commitChanges(failureMessage: "既定の集中時間を保存できませんでした。") {
            settingsError = error
        }
    }

    private func updateReminder(enabled: Bool) {
        updatePassiveNotification(.dailyReminder, enabled: enabled)
    }

    private func updateWrappedNotification(enabled: Bool) {
        updatePassiveNotification(.wrapped, enabled: enabled)
    }

    private func updatePassiveNotification(
        _ preference: PassiveNotificationPreference,
        enabled: Bool
    ) {
        guard prefs != nil else { return }
        Task { @MainActor in
            let manager = NotificationManager.shared
            if enabled {
                await manager.refreshAuthorizationStatus()
                var granted = manager.isAuthorized
                if !granted {
                    granted = await manager.requestAuthorization()
                }
                guard granted else {
                    disableNotificationPreference(preference)
                    notificationError = notificationPermissionMessage(
                        underlyingError: manager.lastErrorDescription
                    )
                    await synchronizeNotificationsNow()
                    return
                }
            }

            switch preference {
            case .dailyReminder:
                guard let prefs else { return }
                prefs.reminderEnabled = enabled
                if let error = commitChanges(failureMessage: "毎日のリマインダ設定を保存できませんでした。") {
                    settingsError = error
                    return
                }
            case .wrapped:
                wrappedNotifications = enabled
            }

            await synchronizeNotificationsNow()
        }
    }

    private func synchronizeNotifications() {
        Task { @MainActor in
            await synchronizeNotificationsNow()
        }
    }

    private func resetStudyData() {
        let prefsToAdvance = prefs

        let marker: ActivityResetMarker
        do {
            marker = try ActivityResetStore.beginReset(
                context: modelContext,
                deviceID: FocusDeviceIdentity.current()
            )
        } catch {
            settingsError = "リセット情報を安全に保存できませんでした。\n\(error.localizedDescription)"
            return
        }

        // The append-only marker is the atomic deletion boundary. Every view
        // immediately rejects the previous generation, and offline devices
        // learn the same rule through CloudKit. Eagerly materializing and
        // deleting hundreds of thousands of rows here made Settings itself an
        // unrecoverable main-thread freeze for long-lived accounts. Physical
        // row compaction is maintenance, never a prerequisite for reset.
        prefsToAdvance?.activityEpochID = marker.epochID
        prefsToAdvance?.manualDayKey = FairnessPolicy.deviceDayKey(for: .now)
        prefsToAdvance?.manualUsedToday = 0
        if let error = commitChanges(failureMessage: "記録をリセットできませんでした。") {
            settingsError = error
            return
        }

        FocusPersistence.clear()
        FocusPersistence.clearBreak()
        PendingStratumCelebrationStore.removeAll()
        PendingRewardReceiptStore.removeAll()
        FocusRestCadenceStore.removeAll()
        UserDefaults.standard.removeObject(forKey: FocusPersistence.localCompletionIDKey)
        UserDefaults.standard.removeObject(forKey: "review.local-completion-count")
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix("wrapped.") || key.hasPrefix("share.prompt.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        router.showToast(
            "記録をリセットしました。ほかの端末にはiCloud接続後に反映されます",
            symbol: "trash"
        )

        Task { @MainActor in
            await NotificationManager.shared.cancelAllTimerNotifications()
            await FocusActivityManager.shared.endAll()
            do {
                try await WidgetSnapshotStore.shared.clear()
            } catch {
                settingsError = "この端末の記録はリセット済みですが、ウィジェットの表示を消去できませんでした。iCloudへの反映には時間がかかる場合があります。\n\(error.localizedDescription)"
            }
        }
    }

    private func updateSetting(
        _ target: Prefs,
        _ keyPath: ReferenceWritableKeyPath<Prefs, Bool>,
        value: Bool
    ) {
        // `settingBinding` normally applied the value through @Bindable
        // already. Keep this fallback so this persistence boundary remains
        // correct if it is reused by a non-projected caller later.
        if target[keyPath: keyPath] != value {
            target[keyPath: keyPath] = value
        }
        if let error = commitChanges(failureMessage: "設定を保存できませんでした。") {
            settingsError = error
            return
        }

        if keyPath == \Prefs.soundOn {
            SoundSynth.shared.isEnabled = value
            synchronizeNotifications()
        }
        if keyPath == \Prefs.hapticsOn {
            Haptics.shared.isEnabled = value
        }
    }

    private func commitChanges(failureMessage: String) -> String? {
        do {
            try modelContext.save()
            return nil
        } catch {
            modelContext.rollback()
            return "\(failureMessage)\n変更前の状態に戻しました。\n\(error.localizedDescription)"
        }
    }

    private func disableNotificationPreference(_ preference: PassiveNotificationPreference) {
        switch preference {
        case .dailyReminder:
            guard let prefs, prefs.reminderEnabled else { return }
            prefs.reminderEnabled = false
            if let error = commitChanges(failureMessage: "毎日のリマインダをオフにできませんでした。") {
                settingsError = error
            }
        case .wrapped:
            wrappedNotifications = false
        }
    }

    private func reconcileNotificationAuthorization() async {
        guard let prefs else { return }
        let manager = NotificationManager.shared
        await manager.refreshAuthorizationStatus()

        if !manager.isAuthorized {
            let hadEnabledPreference = prefs.reminderEnabled || wrappedNotifications
            if prefs.reminderEnabled {
                prefs.reminderEnabled = false
                if let error = commitChanges(failureMessage: "通知の実際の状態を保存できませんでした。") {
                    settingsError = error
                }
            }
            wrappedNotifications = false

            if hadEnabledPreference {
                notificationError = notificationPermissionMessage(underlyingError: nil)
            }
        }

        await synchronizeNotificationsNow()
    }

    private func synchronizeNotificationsNow() async {
        guard let prefs else { return }
        let manager = NotificationManager.shared
        await manager.refreshAuthorizationStatus()
        do {
            try await manager.synchronizePassiveNotifications(
                dailyReminderEnabled: prefs.reminderEnabled && manager.isAuthorized,
                wrappedEnabled: wrappedNotifications && manager.isAuthorized,
                hour: prefs.reminderHour,
                minute: prefs.reminderMinute,
                playsSound: prefs.soundOn
            )
        } catch {
            notificationError = "通知の予定を更新できませんでした。\n\(error.localizedDescription)"
        }
    }

    private func notificationPermissionMessage(underlyingError: String?) -> String {
        let message = "通知が許可されていません。端末の「設定」から「つみべん」の通知を許可してください。"
        guard let underlyingError, !underlyingError.isEmpty else { return message }
        return "\(message)\n\(underlyingError)"
    }

    private enum PassiveNotificationPreference {
        case dailyReminder
        case wrapped
    }
}

private struct FontLicenseView: View {
    @Environment(\.dismiss) private var dismiss

    private var licenseText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE-fonts", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "ライセンス文書を読み込めませんでした。" }
        return text
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(licenseText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(TsumibenTheme.muted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(NightBackground())
            .navigationTitle("フォントライセンス")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    TsumibenSheetCloseButton(
                        accessibilityIdentifier: "font-license.close"
                    ) {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct SubjectReorderAccessibilityModifier: ViewModifier {
    let index: Int
    let count: Int
    let moveUp: () -> Void
    let moveDown: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if count <= 1 {
            content
        } else if index == 0 {
            content.accessibilityAction(named: "下へ移動", moveDown)
        } else if index == count - 1 {
            content.accessibilityAction(named: "上へ移動", moveUp)
        } else {
            content
                .accessibilityAction(named: "上へ移動", moveUp)
                .accessibilityAction(named: "下へ移動", moveDown)
        }
    }
}

private struct SettingLabel: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(TsumibenTheme.text)
                Text(subtitle).font(.caption).foregroundStyle(TsumibenTheme.muted)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(TsumibenTheme.amber).frame(width: 26)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct RarePebbleGuideRow: View {
    let kind: PebbleKind
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(fillStyle)
                    .frame(width: 30, height: 30)
                    .overlay {
                        Circle()
                            .strokeBorder(strokeColor, lineWidth: kind == .normal ? 1 : 2)
                    }
                    .shadow(color: glowColor, radius: kind == .normal ? 0 : 6)

                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(TsumibenTheme.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(TsumibenTheme.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch kind {
        case .normal: "circle.fill"
        case .gold: "sparkle"
        case .prism: "diamond.fill"
        }
    }

    private var fillStyle: AnyShapeStyle {
        switch kind {
        case .normal:
            AnyShapeStyle(Color(hex: Constants.Color.mathematics))
        case .gold:
            AnyShapeStyle(
                LinearGradient(
                    colors: [Color(hex: Constants.Color.pebbleGold), .white.opacity(0.86)],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )
            )
        case .prism:
            AnyShapeStyle(
                AngularGradient(
                    colors: [.pink, .orange, .yellow, .mint, .cyan, .indigo, .pink],
                    center: .center
                )
            )
        }
    }

    private var strokeColor: Color {
        switch kind {
        case .normal: .white.opacity(0.34)
        case .gold: .white.opacity(0.82)
        case .prism: .white.opacity(0.92)
        }
    }

    private var glowColor: Color {
        switch kind {
        case .normal: .clear
        case .gold: Color(hex: Constants.Color.pebbleGold).opacity(0.38)
        case .prism: .cyan.opacity(0.34)
        }
    }
}

private struct SubjectEditorView: View {
    let subject: Subject?
    let suggestedColorHex: String
    let usagePurpose: UsagePurpose
    let onSave: (String, String, Bool) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var colorHex: String
    @State private var isArchived: Bool
    @State private var saveError: String?

    private let palette = [
        SubjectColorChoice(hex: Constants.Color.english, name: "朱色"),
        SubjectColorChoice(hex: Constants.Color.mathematics, name: "瑠璃"),
        SubjectColorChoice(hex: Constants.Color.japanese, name: "紅藤"),
        SubjectColorChoice(hex: Constants.Color.science, name: "緑青"),
        SubjectColorChoice(hex: Constants.Color.socialStudies, name: "菫"),
        SubjectColorChoice(hex: "#D6863A", name: "琥珀"),
        SubjectColorChoice(hex: "#36A7AE", name: "青緑"),
        SubjectColorChoice(hex: "#D56B82", name: "珊瑚"),
        SubjectColorChoice(hex: "#739B45", name: "若草"),
        SubjectColorChoice(hex: "#5967C8", name: "藍"),
        SubjectColorChoice(hex: "#A76A3F", name: "赤銅"),
        SubjectColorChoice(hex: "#5688A8", name: "空色")
    ]

    private var nameValidationError: SubjectNamePolicy.ValidationError? {
        SubjectNamePolicy.validationError(for: name)
    }

    private var nameIsTooLong: Bool {
        guard let nameValidationError else { return false }
        if case .tooLong = nameValidationError { return true }
        return false
    }

    private var nameStatusMessage: String {
        if nameIsTooLong, let nameValidationError {
            return nameValidationError.message
        }
        if SubjectNamePolicy.trimmed(name).isEmpty {
            return "1〜\(SubjectNamePolicy.maximumCharacters)文字で入力してください。"
        }
        return "あと\(SubjectNamePolicy.remainingCharacters(for: name))文字入力できます。"
    }

    init(
        subject: Subject?,
        suggestedColorHex: String,
        usagePurpose: UsagePurpose,
        onSave: @escaping (String, String, Bool) -> String?
    ) {
        self.subject = subject
        self.suggestedColorHex = suggestedColorHex
        self.usagePurpose = usagePurpose
        self.onSave = onSave
        _name = State(initialValue: subject?.name ?? "")
        _colorHex = State(initialValue: subject?.colorHex ?? suggestedColorHex)
        _isArchived = State(initialValue: subject?.isArchived ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(usagePurpose.customFieldPlaceholder, text: $name)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.done)
                        .accessibilityHint("カテゴリ名は\(SubjectNamePolicy.maximumCharacters)文字までです")
                } header: {
                    Text("名前")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(nameStatusMessage)
                            .foregroundStyle(nameIsTooLong ? Color.red : TsumibenTheme.muted)
                            .accessibilityLabel(nameStatusMessage)
                        if let privacyGuidance = usagePurpose.privacyGuidance {
                            Text(privacyGuidance)
                                .foregroundStyle(TsumibenTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let professionalUseGuidance = usagePurpose.professionalUseGuidance {
                            Text(professionalUseGuidance)
                                .foregroundStyle(TsumibenTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Section("粒の色") {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 64, maximum: 92), spacing: 8)],
                        spacing: 12
                    ) {
                        ForEach(Array(palette.enumerated()), id: \.element.id) { index, choice in
                            Button {
                                colorHex = choice.hex
                            } label: {
                                VStack(spacing: 5) {
                                    Circle()
                                        .fill(Color(hex: choice.hex))
                                        .frame(width: 34, height: 34)
                                        .overlay {
                                            if colorHex == choice.hex {
                                                Circle().stroke(.white, lineWidth: 3).padding(-4)
                                            }
                                        }
                                    Text("\(index + 1) \(choice.name)")
                                        .font(.caption2)
                                        .foregroundStyle(TsumibenTheme.text)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                }
                                .frame(maxWidth: .infinity, minHeight: 60)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(TsumibenBareButtonStyle())
                            .accessibilityLabel("色候補\(index + 1)、\(choice.name)")
                            .accessibilityAddTraits(colorHex == choice.hex ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 8)
                }
                if let subject {
                    Section {
                        Toggle("ホームの選択肢に表示", isOn: Binding(
                            get: { !isArchived },
                            set: { isArchived = !$0 }
                        ))
                    } footer: {
                        Text("非表示にしても、\(subject.safeDisplayName)の過去の粒は瓶に残ります。")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(NightBackground())
            .navigationTitle(subject == nil ? "\(usagePurpose.categoryTitle)を追加" : "カテゴリを編集")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let sanitizedName = SubjectNamePolicy.validated(name) else {
                            saveError = nameValidationError?.message
                                ?? "カテゴリ名を入力してください。"
                            return
                        }
                        let error = onSave(
                            sanitizedName,
                            colorHex,
                            isArchived
                        )
                        if let error {
                            saveError = error
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(nameValidationError != nil)
                }
            }
            .alert("保存できませんでした", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }
}

private struct TsumibenDataExportShareSheet: UIViewControllerRepresentable {
    let fileURL: URL
    let completion: (Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
        controller.allowsProminentActivity = true
        controller.completionWithItemsHandler = { _, _, _, error in
            DispatchQueue.main.async {
                completion(error)
            }
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private struct SubjectColorChoice: Identifiable {
    let hex: String
    let name: String

    var id: String { hex }
}

private extension UIColor {
    var hexString: String {
        guard let components = cgColor.components, components.count >= 3 else { return Constants.Color.textMute }
        let red = Int(round(components[0] * 255))
        let green = Int(round(components[1] * 255))
        let blue = Int(round(components[2] * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
