import FamilyControls
import SwiftData
import SwiftUI

/// Selections remain drafts until the user explicitly saves. The controller
/// repeats these checks before registering any Device Activity monitoring.
struct ScreenTimeSettingsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var controller = ScreenTimeController.shared
    @State private var purchase = PurchaseManager.shared
    @Query private var storedSubjects: [Subject]
    @State private var draft: ScreenTimeConfiguration
    @State private var selectionLane: ScreenTimeSelectionLane?
    @State private var isRequestingAuthorization = false
    @State private var saveError: String?
    @State private var isResetConfirmationPresented = false
    @State private var hasUserEdits = false

    init() {
        _draft = State(initialValue: ScreenTimeController.shared.configuration)
        var descriptor = FetchDescriptor<Subject>(sortBy: [
            SortDescriptor(\Subject.sortOrder),
            SortDescriptor(\Subject.createdAt),
            SortDescriptor(\Subject.id)
        ])
        descriptor.fetchLimit = SubjectSyncPolicy.maximumPhysicalRows + 1
        _storedSubjects = Query(descriptor)
    }

    private var subjects: [Subject] {
        SubjectSyncPolicy.presentationSubjects(from: storedSubjects)
    }

    private var learningCount: Int { draft.learningSelection.applicationTokens.count }
    private var distractionCount: Int { draft.distractionSelection.applicationTokens.count }

    private var selectedThemeExists: Bool {
        subjects.contains { $0.id == draft.themeID }
    }

    private var validationMessage: String? {
        // Revoked permission, a removed theme, or a changed Pro entitlement must
        // never prevent the user from switching this feature off.
        guard draft.enabled else { return nil }
        guard controller.authorizationGranted else {
            return "スクリーンタイムへのアクセスを許可してください。"
        }
        if let message = ScreenTimeSelectionValidation.message(
            selection: draft.learningSelection,
            otherSelection: draft.distractionSelection,
            lane: .learning,
            isPro: purchase.isPro
        ) {
            return message
        }
        if let message = ScreenTimeSelectionValidation.message(
            selection: draft.distractionSelection,
            otherSelection: draft.learningSelection,
            lane: .distraction,
            isPro: purchase.isPro
        ) {
            return message
        }
        guard learningCount + distractionCount > 0 else {
            return "記録するアプリを1つ以上選んでください。"
        }
        if learningCount > 0 && !selectedThemeExists {
            return "勉強時間を記録するテーマを選んでください。"
        }
        return nil
    }

    var body: some View {
        List {
            introductionSection
            authorizationSection
            recordingSection
            learningSection
            distractionSection
            detailsSection
            resetSection
        }
        .scrollContentBackground(.hidden)
        .background(NightBackground())
        .navigationTitle("スクリーンタイム")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
                    .disabled(ScreenTimeDraftPolicy.blocksSave(
                        bound: controller.isBoundToContext, draftEnabled: draft.enabled
                    ) || isRequestingAuthorization
                              || controller.isSaving || controller.isResetting || validationMessage != nil)
                    .accessibilityIdentifier("screen-time.save")
            }
        }
        .sheet(item: $selectionLane) { lane in
            ScreenTimeAppSelectionSheet(
                lane: lane,
                initialSelection: lane == .learning
                    ? draft.learningSelection : draft.distractionSelection,
                otherSelection: lane == .learning
                    ? draft.distractionSelection : draft.learningSelection,
                isPro: purchase.isPro
            ) { selection in
                hasUserEdits = true
                if lane == .learning {
                    draft.learningSelection = selection
                } else {
                    draft.distractionSelection = selection
                }
            }
        }
        .alert("設定を完了できませんでした", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
        .alert("スクリーンタイムの内容をリセット", isPresented: $isResetConfirmationPresented) {
            Button("キャンセル", role: .cancel) {}
            Button("リセット", role: .destructive, action: reset)
        } message: {
            Text("アプリの選択、まだ取り込んでいない利用記録、黒いgemをこのiPhoneから削除し、自動記録を停止します。取り消せません。保存済みの勉強時間と通常gemは残ります。")
        }
        .task {
            controller.reload()
            seedDraftIfNeeded()
        }
        .onChange(of: controller.isBoundToContext) { _, _ in
            // The controller publishes an empty configuration until the ledger
            // admits this owner, which can happen after this screen appears.
            seedDraftIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.reload() }
        }
        .onChange(of: controller.configuration) { _, configuration in
            // Permission revocation invalidates opaque selections. Ordinary
            // background refreshes must not overwrite the user's draft edits.
            if !controller.authorizationGranted {
                draft = configuration
                hasUserEdits = false
            }
        }
    }

    private var introductionSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text("アプリで過ごした時間を、gemに。")
                        .font(.headline)
                        .foregroundStyle(PomoGemTheme.text)
                    Text("選んだアプリの利用時間を合計して、10分ごとにじゃらっと積みます。")
                        .font(.subheadline)
                        .foregroundStyle(PomoGemTheme.muted)
                }
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "diamond.fill")
                    .foregroundStyle(PomoGemTheme.amber)
                    .accessibilityHidden(true)
            }
        }
    }

    private var authorizationSection: some View {
        Section {
            Label {
                Text(authorizationStatusText)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: controller.authorizationGranted ? "checkmark.shield" : "hand.raised")
                    .accessibilityHidden(true)
            }
            .foregroundStyle(controller.authorizationGranted ? PomoGemTheme.text : PomoGemTheme.muted)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(authorizationStatusText)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("screen-time.authorization-status")

            if !controller.authorizationGranted {
                Button {
                    Task { await requestAuthorization() }
                } label: {
                    HStack(spacing: 10) {
                        if isRequestingAuthorization { ProgressView() }
                        Text(isRequestingAuthorization ? "許可を確認中…" : "アクセスを許可")
                    }
                    .frame(minHeight: 44)
                }
                .disabled(isRequestingAuthorization)
                .accessibilityIdentifier("screen-time.authorize")
            }
        } header: {
            Text("スクリーンタイムへのアクセス")
        } footer: {
            if controller.authorizationStatus == .denied {
                Text("アクセスが許可されていないため、自動記録は停止しています。「アクセスを許可」からもう一度確認してください。")
            } else {
                Text("このiPhoneで使うアプリを、Appleの選択画面から指定します。")
            }
        }
    }

    private var recordingSection: some View {
        Section {
            Toggle("アプリの利用時間を記録", isOn: editedBinding(\.enabled))
                .disabled(controller.isSaving || controller.isResetting || (!controller.authorizationGranted && !draft.enabled))
                .accessibilityHint("アプリとテーマを選び、保存すると反映されます")
                .accessibilityIdentifier("screen-time.enabled")

            if let message = controller.monitoringError ?? controller.bindingError {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(message)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityIdentifier("screen-time.monitoring-error")
            }
            if controller.isUpdatingMonitoring {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("スクリーンタイムの設定を反映中…")
                        .font(.subheadline)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("screen-time.updating")
            } else if controller.isMonitoring {
                Label(monitoringStatusText, systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(PomoGemTheme.muted)
            } else {
                Text("自動記録は停止中です。")
                    .font(.subheadline)
                    .foregroundStyle(PomoGemTheme.muted)
            }

            if controller.learningPausedByTimer {
                Text("タイマーの計測中は、勉強アプリの自動記録を休止しています。")
                    .font(.subheadline)
                    .foregroundStyle(PomoGemTheme.muted)
            }
        } footer: {
            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
            } else if !controller.isBoundToContext {
                Text(ScreenTimeDraftPolicy.unboundFooterMessage)
            } else {
                Text("変更は右上の「保存」で反映します。記録を再開できないときも、保存から再試行できます。")
            }
        }
    }

    private var learningSection: some View {
        Section {
            selectionButton(.learning, count: learningCount)

            Picker("記録先のテーマ", selection: editedBinding(\.themeID)) {
                Text("選んでください").tag(nil as UUID?)
                if let themeID = draft.themeID, !selectedThemeExists {
                    Text("削除されたテーマ").tag(Optional(themeID))
                }
                ForEach(subjects, id: \.id) { subject in
                    Text(subject.safeDisplayName).tag(Optional(subject.id))
                }
            }
            .disabled(controller.isSaving || controller.isResetting)
            .accessibilityIdentifier("screen-time.theme")

            if !purchase.isPro {
                Button {
                    router.presentPaywall(from: .screenTimeApps)
                } label: {
                    Label("Proで勉強アプリを無制限に", systemImage: "sparkles")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("screen-time.pro")
            }
        } header: {
            Text("勉強のgem")
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text("10分ごとに、選んだテーマへ10分ぶんのgemと勉強時間を追加します。")
                Text(purchase.isPro ? "Pro：アプリ数は無制限です。" : "無料：5つまで。Pro：無制限。")
                if learningCount > 0 && !selectedThemeExists {
                    Text("テーマが未選択、または削除されています。記録先を選び直してください。")
                        .foregroundStyle(.red)
                }
                if !purchase.isPro && learningCount > 5 {
                    Text("現在の選択は無料枠を超えています。5つ以下に減らすか、Proの購入を確認してください。")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var distractionSection: some View {
        Section {
            selectionButton(.distraction, count: distractionCount)
            VStack(alignment: .leading, spacing: 4) {
                Text("黒いgem：10分 × \(max(0, controller.negativeGemCount).formatted())個ぶん")
                Text("累計 \(negativeDurationText)")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("黒いgem、10分 × \(max(0, controller.negativeGemCount).formatted())個ぶん、累計 \(negativeDurationText)")
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("screen-time.negative-total")
        } header: {
            Text("黒いgem")
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text("SNSなど、控えたいアプリを選べます。10分ごとに、瓶の中で邪魔な石になる黒い塊を追加します。")
                Text("黒いgem同士だけが結合します。勉強時間には加算されません。")
                Text("無料でもアプリ数は無制限です。")
            }
        }
    }

    private var detailsSection: some View {
        Section {
            Text("勉強アプリと黒いgemのアプリは別々に合計します。同じアプリを両方には登録できません。")
            Text("次にポモジェムを開くと、届いた記録を瓶に反映します。反映が遅れることがあります。")
            Text("一部のアプリは、OSが関連Webサイトの利用も含める場合があります。")
            Text("10分未満の端数は、日付の切り替わりや設定の変更・停止でリセットされます。タイマー中の二重加算を避けるため、勉強アプリの計測もいったん区切ります。")
            Text("アプリの選択、未取り込みの利用記録、黒いgemは、このiPhoneだけに保存します。JSON書き出しや保存先の切り替えでは引き継ぎません。")
        } header: {
            Text("記録について")
        }
        .font(.subheadline)
        .foregroundStyle(PomoGemTheme.muted)
    }

    private var resetSection: some View {
        Section {
            Button("スクリーンタイムの内容をリセット", role: .destructive) {
                isResetConfirmationPresented = true
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44)
            .disabled(controller.isSaving || controller.isResetting || isRequestingAuthorization)
            .accessibilityIdentifier("screen-time.reset")
        } footer: {
            Text("アプリの選択・未取り込みの利用記録・黒いgemを削除し、自動記録を停止します。保存済みの勉強時間と通常gemは残ります。")
        }
    }

    private var monitoringStatusText: String {
        let learningOverLimit = !purchase.isPro
            && controller.configuration.learningSelection.applicationTokens.count
                > ScreenTimePolicy.freeLearningApplicationLimit
        return controller.learningPausedByTimer || learningOverLimit
            ? "黒いgemを自動記録中" : "自動記録中"
    }

    private var authorizationStatusText: String {
        controller.authorizationGranted ? "アクセス許可済み" : "アクセスの許可が必要です"
    }

    private var negativeDurationText: String {
        let (minutes, overflow) = max(0, controller.negativeGemCount)
            .multipliedReportingOverflow(by: ScreenTimePolicy.minutesPerGem)
        return overflow ? "\(Int.max.formatted())分以上" : "\(minutes.formatted())分"
    }

    private func selectionButton(_ lane: ScreenTimeSelectionLane, count: Int) -> some View {
        Button {
            selectionLane = lane
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: lane == .learning ? "apps.iphone" : "circle.hexagongrid.fill")
                    .foregroundStyle(lane == .learning ? PomoGemTheme.amber : PomoGemTheme.muted)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("アプリを選ぶ")
                        .foregroundStyle(PomoGemTheme.text)
                    Text(lane == .learning && !purchase.isPro
                         ? "\(count) / 5アプリ"
                         : "\(count)アプリ・無制限")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(PomoGemBareButtonStyle())
        .disabled(!controller.authorizationGranted || isRequestingAuthorization || controller.isSaving || controller.isResetting)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(lane.title)のアプリを選ぶ")
        .accessibilityValue("\(count)アプリ選択中")
        .accessibilityHint(lane == .learning && !purchase.isPro ? "無料では5つまで選べます" : "アプリ数は無制限です")
        .accessibilityIdentifier("screen-time.\(lane.rawValue)-apps")
    }

    /// Only user interaction goes through this setter, so a later re-seed
    /// cannot be mistaken for an edit the user can see on screen.
    private func editedBinding<Value: Equatable>(
        _ keyPath: WritableKeyPath<ScreenTimeConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { newValue in
                guard draft[keyPath: keyPath] != newValue else { return }
                hasUserEdits = true
                draft[keyPath: keyPath] = newValue
            }
        )
    }

    private func seedDraftIfNeeded() {
        guard ScreenTimeDraftPolicy.shouldReseed(
            bound: controller.isBoundToContext,
            hasUserEdits: hasUserEdits,
            draftIsEmpty: draft == ScreenTimeConfiguration()
        ) else { return }
        draft = controller.configuration
        hasUserEdits = false
    }

    private func requestAuthorization() async {
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        defer { isRequestingAuthorization = false }
        await controller.requestAuthorization()
        draft = controller.configuration
        hasUserEdits = false
    }

    private func save() {
        guard validationMessage == nil, !controller.isSaving, !controller.isResetting else { return }
        let configuration = draft
        let isPro = purchase.isPro
        Task {
            do {
                try await controller.save(configuration: configuration, isPro: isPro)
                draft = controller.configuration
                hasUserEdits = false
                if controller.monitoringError == nil {
                    router.showToast("スクリーンタイムの設定を保存しました", symbol: "checkmark")
                }
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func reset() {
        Task {
            do {
                try await controller.resetActivityData()
                draft = controller.configuration
                hasUserEdits = false
                router.showToast("スクリーンタイムの内容をリセットしました", symbol: "checkmark")
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}

/// Seeding the draft from an unbound controller shows an empty configuration;
/// saving that would erase application tokens the user can only restore through
/// a new picker session. An empty draft has nothing to lose, so a late binding
/// may still fill it in.
enum ScreenTimeDraftPolicy {
    static func shouldReseed(bound: Bool, hasUserEdits: Bool, draftIsEmpty: Bool) -> Bool {
        guard bound else { return false }
        return !hasUserEdits || draftIsEmpty
    }

    /// 保存 stays enabled while the context is unbound and the draft is OFF so
    /// the user gets the concrete reason from the 「設定を完了できませんでした」
    /// alert instead of a mute greyed-out control. It does NOT mean the save
    /// succeeds: `ScreenTimeController.save` starts with `boundLease()`, which
    /// throws `unboundContext` for every save while unbound. A save that would
    /// ENABLE recording is blocked outright, because its draft may still be
    /// the controller's empty published configuration and saving that would
    /// destroy opaque selections only a new picker session could restore.
    static func blocksSave(bound: Bool, draftEnabled: Bool) -> Bool {
        !bound && draftEnabled
    }

    /// What the footer says while the context is unbound. It must describe the
    /// button's real effect — an explanation — and never promise a save the
    /// controller refuses.
    static let unboundFooterMessage =
        "記録の準備が完了していないため、いまは変更を保存できません。「保存」を押すと、理由をお知らせします。"
}

private enum ScreenTimeSelectionLane: String, Identifiable {
    case learning
    case distraction

    var id: String { rawValue }
    var title: String { self == .learning ? "勉強のgem" : "黒いgem" }
}

private enum ScreenTimeSelectionValidation {
    static func message(
        selection: FamilyActivitySelection,
        otherSelection: FamilyActivitySelection,
        lane: ScreenTimeSelectionLane,
        isPro: Bool
    ) -> String? {
        if !selection.categoryTokens.isEmpty || !selection.webDomainTokens.isEmpty {
            return "カテゴリやWebサイトは選べません。カテゴリを開き、アプリを1つずつ選んでください。"
        }
        if !selection.applicationTokens.isDisjoint(with: otherSelection.applicationTokens) {
            return "同じアプリを勉強のgemと黒いgemの両方には登録できません。もう一方の選択から外してください。"
        }
        if lane == .learning && !isPro
            && selection.applicationTokens.count > ScreenTimePolicy.freeLearningApplicationLimit {
            return "無料では勉強アプリを5つまで選べます。5つ以下に減らしてください。Proでは無制限です。"
        }
        return nil
    }
}

private struct ScreenTimeAppSelectionSheet: View {
    let lane: ScreenTimeSelectionLane
    let otherSelection: FamilyActivitySelection
    let isPro: Bool
    let onApply: (FamilyActivitySelection) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: FamilyActivitySelection

    init(
        lane: ScreenTimeSelectionLane,
        initialSelection: FamilyActivitySelection,
        otherSelection: FamilyActivitySelection,
        isPro: Bool,
        onApply: @escaping (FamilyActivitySelection) -> Void
    ) {
        self.lane = lane
        self.otherSelection = otherSelection
        self.isPro = isPro
        self.onApply = onApply
        // Do not allow an entire category to implicitly opt future apps in.
        var explicitSelection = FamilyActivitySelection(includeEntireCategory: false)
        explicitSelection.applicationTokens = initialSelection.applicationTokens
        _selection = State(initialValue: explicitSelection)
    }

    private var validationMessage: String? {
        ScreenTimeSelectionValidation.message(
            selection: selection,
            otherSelection: otherSelection,
            lane: lane,
            isPro: isPro
        )
    }

    var body: some View {
        NavigationStack {
            FamilyActivityPicker(
                headerText: "カテゴリを開き、記録するアプリを1つずつ選んでください。",
                footerText: lane == .learning && !isPro
                    ? "無料は5つまで。Proでは無制限です。"
                    : "アプリ数は無制限です。",
                selection: $selection
            )
            .navigationTitle("\(lane.title)のアプリ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("反映") {
                        guard validationMessage == nil else { return }
                        onApply(selection)
                        dismiss()
                    }
                    .disabled(validationMessage != nil)
                    .accessibilityIdentifier("screen-time.picker-apply")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(selection.applicationTokens.count)アプリ選択中")
                        .font(.subheadline.weight(.semibold))
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.regularMaterial)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
