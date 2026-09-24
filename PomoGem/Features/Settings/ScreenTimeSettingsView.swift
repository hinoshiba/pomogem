import FamilyControls
import SwiftData
import SwiftUI
import UIKit

/// Selections remain drafts until the user explicitly saves. The controller
/// repeats these checks before registering any Device Activity monitoring.
struct ScreenTimeSettingsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ObservedObject private var controller: ScreenTimeController
    @State private var purchase = PurchaseManager.shared
    @Environment(\.modelContext) private var modelContext
    /// Live theme rows only; tombstones never count toward the row bound.
    @Query private var storedSubjects: [Subject]
    /// Observed so a deletion delivered as a new physical row refreshes the
    /// list; see `SubjectSyncPolicy.presentationSubjects(live:tombstones:context:)`.
    @Query private var storedSubjectTombstones: [Subject]
    @State private var draft: ScreenTimeConfiguration
    @State private var selectionLane: ScreenTimeSelectionLane?
    @State private var isRequestingAuthorization = false
    @State private var saveError: String?
    @State private var isResetConfirmationPresented = false
    @State private var isClearBlackStonesConfirmationPresented = false
    @State private var hasUserEdits = false
    @State private var isLeaveConfirmationPresented = false
    /// Set by 「保存して戻る」: pop once the save has finished, never while it
    /// runs (the user can still go back themselves meanwhile).
    @State private var leavesAfterSave = false
    @State private var isVisible = false
    @Environment(\.dismiss) private var dismiss

    /// Production always uses the shared controller; the parameter exists so
    /// the Simulator UI-test fixture can drive a temporary ledger that really
    /// binds. Without entitlements the shared controller's App Group container
    /// is nil and `isBoundToContext` can never become true, which would leave
    /// the unbound -> bound draft re-seed with no automated coverage at all.
    @MainActor
    init(controller: ScreenTimeController? = nil) {
        let controller = controller ?? .shared
        _controller = ObservedObject(wrappedValue: controller)
        _draft = State(initialValue: controller.configuration)
        _storedSubjects = Query(SubjectSyncPolicy.liveRowsDescriptor(sortBy: [
            SortDescriptor(\Subject.sortOrder),
            SortDescriptor(\Subject.createdAt),
            SortDescriptor(\Subject.id)
        ]))
        _storedSubjectTombstones = Query(SubjectSyncPolicy.tombstoneRowsDescriptor())
    }

    private var subjects: [Subject] {
        SubjectSyncPolicy.presentationSubjects(
            live: storedSubjects, tombstones: storedSubjectTombstones, context: modelContext
        )
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

    /// Edits the user made that 保存 has not applied. The back button asks
    /// before it throws them away; the picker's selections in particular can
    /// only be rebuilt one app at a time in Apple's picker. Never true while a
    /// save or reset runs, so going back stays possible during registration.
    private var hasUnsavedChanges: Bool {
        hasUserEdits && draft != controller.configuration
            && !controller.isSaving && !controller.isResetting
    }

    private var canSaveDraft: Bool {
        !ScreenTimeDraftPolicy.blocksSave(bound: controller.isBoundToContext, draftEnabled: draft.enabled)
            && !isRequestingAuthorization && !controller.isSaving && !controller.isResetting
            && validationMessage == nil
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
        // The system back button would drop unsaved edits without a word.
        .navigationBarBackButtonHidden(hasUnsavedChanges)
        .toolbar {
            if hasUnsavedChanges {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isLeaveConfirmationPresented = true
                    } label: {
                        Label(String(localized: "戻る", table: "ScreenTime",
                                     comment: "Back button shown while Screen Time edits are unsaved"),
                              systemImage: "chevron.backward")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityIdentifier("screen-time.back")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
                    .disabled(ScreenTimeDraftPolicy.blocksSave(
                        bound: controller.isBoundToContext, draftEnabled: draft.enabled
                    ) || isRequestingAuthorization
                              || controller.isSaving || controller.isResetting || validationMessage != nil)
                    .accessibilityIdentifier("screen-time.save")
            }
        }
        .confirmationDialog(
            String(localized: "変更が保存されていません", table: "ScreenTime",
                   comment: "Dialog title: leaving Screen Time settings with unsaved edits"),
            isPresented: $isLeaveConfirmationPresented,
            titleVisibility: .visible
        ) {
            if canSaveDraft {
                Button(String(localized: "保存して戻る", table: "ScreenTime",
                              comment: "Dialog action: save the Screen Time edits, then go back")) {
                    leavesAfterSave = true
                    save()
                }
            }
            Button(String(localized: "変更を破棄して戻る", table: "ScreenTime",
                          comment: "Dialog action: drop the Screen Time edits and go back"),
                   role: .destructive) {
                draft = controller.configuration
                hasUserEdits = false
                dismiss()
            }
            Button(String(localized: "編集を続ける", table: "ScreenTime",
                          comment: "Dialog action: stay on the Screen Time settings"),
                   role: .cancel) {}
        } message: {
            if canSaveDraft {
                Text("選んだアプリや記録の設定は、保存するまで反映されません。",
                     tableName: "ScreenTime", comment: "Dialog message: unsaved Screen Time edits")
            } else {
                Text("選んだアプリや記録の設定は、保存するまで反映されません。いまの内容のままでは保存できないため、戻ると変更は破棄されます。",
                     tableName: "ScreenTime", comment: "Dialog message: unsaved Screen Time edits that cannot be saved yet")
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
                draft = ScreenTimeDraftPolicy.applying(
                    selection,
                    toLearningLane: lane == .learning,
                    in: draft,
                    authorized: controller.authorizationGranted,
                    onlyThemeID: subjects.count == 1 ? subjects.first?.id : nil
                )
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
        .alert(String(localized: "黒い石を片付けますか？", table: "ScreenTime",
                      comment: "Alert title: clear only the black stones"),
               isPresented: $isClearBlackStonesConfirmationPresented) {
            Button("キャンセル", role: .cancel) {}
            Button(String(localized: "片付ける", table: "ScreenTime", comment: "Alert action: clear the black stones"),
                   action: clearBlackStones)
        } message: {
            Text("瓶の黒い石を、このiPhoneから片付けます。選んだアプリと自動記録はそのまま続き、勉強時間と粒は変わりません。片付けた石は戻せません。",
                 tableName: "ScreenTime", comment: "Alert message: what clearing the black stones does")
        }
        .alert("スクリーンタイムの内容をリセット", isPresented: $isResetConfirmationPresented) {
            Button("キャンセル", role: .cancel) {}
            Button("リセット", role: .destructive, action: reset)
        } message: {
            Text("アプリの選択、まだ取り込んでいない利用記録、黒い石をこのiPhoneから削除し、自動記録を停止します。取り消せません。保存済みの勉強時間と粒は残ります。",
                 tableName: "ScreenTime", comment: "Screen Time reset confirmation")
        }
        .task {
            controller.reload()
            seedDraftIfNeeded()
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
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
                    Text("アプリで過ごした時間も、瓶に。", tableName: "ScreenTime",
                         comment: "Screen Time settings: headline")
                        .font(.headline)
                        .foregroundStyle(PomoGemTheme.text)
                    Text("勉強アプリを使った時間は10分ごとに粒として、控えたいアプリの時間は黒い石として、瓶に積みます。",
                         tableName: "ScreenTime", comment: "Screen Time settings: what the feature does")
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

            if let failure = controller.authorizationFailure, !controller.authorizationGranted {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(failure.message)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityIdentifier("screen-time.authorization-failure")
                if failure.fixIsInSettingsApp {
                    Button {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        openURL(url)
                    } label: {
                        Label(String(localized: "設定アプリを開く", table: "ScreenTime",
                                     comment: "Button: open the iOS Settings app to fix Screen Time access"),
                              systemImage: "gear")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("screen-time.open-settings-app")
                }
            }

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
            VStack(alignment: .leading, spacing: 5) {
                if controller.authorizationStatus == .denied {
                    Text("アクセスが許可されていないため、自動記録は停止しています。「アクセスを許可」からもう一度確認してください。")
                } else {
                    Text("このiPhoneで使うアプリを、Appleの選択画面から指定します。")
                }
                if !controller.authorizationGranted {
                    Text("許可するには、iPhoneのパスコード、Apple Accountへのサインイン、インターネット接続が必要です。",
                         tableName: "ScreenTime", comment: "Footer: prerequisites for Screen Time access")
                }
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
                Text("タイマーの計測中は勉強アプリの自動記録を休止し、終了後に自動で再開します。", tableName: "ScreenTime")
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
            Text("勉強アプリの粒", tableName: "ScreenTime", comment: "Section header: study apps that add pebbles")
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text("選んだアプリを合計10分使うごとに、記録先のテーマへ粒（10分・100g）と勉強時間を追加します。",
                     tableName: "ScreenTime", comment: "Footer: how study-app time becomes pebbles")
                Text(purchase.isPro ? "Pro：アプリ数は無制限です。" : "無料：5つまで。Pro：無制限。")
                if controller.learningThemeWasRemoved && learningCount == 0 {
                    Text("記録先のテーマが削除されたため、勉強アプリの選択を解除しました。アプリとテーマを選び直して保存すると、記録を再開します。",
                         tableName: "ScreenTime", comment: "Footer: the destination theme was deleted and the study apps were cleared")
                        .foregroundStyle(PomoGemTheme.amber)
                        .accessibilityIdentifier("screen-time.theme-removed")
                }
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
                Text("黒い石：10分 × \(max(0, controller.negativeGemCount))個ぶん", tableName: "ScreenTime",
                     comment: "Black-stone total; the number counts ten-minute units")
                Text("累計 \(negativeDurationText)")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("黒い石、10分 × \(max(0, controller.negativeGemCount))個ぶん、累計 \(negativeDurationText)",
                                     tableName: "ScreenTime", comment: "VoiceOver: black-stone total and minutes"))
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("screen-time.negative-total")

            if controller.negativeGemCount > 0 {
                Button {
                    isClearBlackStonesConfirmationPresented = true
                } label: {
                    Label(String(localized: "黒い石を片付ける", table: "ScreenTime",
                                 comment: "Button: clear only the black stones"),
                          systemImage: "sparkles")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44)
                }
                .disabled(controller.isSaving || controller.isResetting)
                .accessibilityIdentifier("screen-time.clear-black-stones")
            }
        } header: {
            Text("黒い石", tableName: "ScreenTime", comment: "Section header: apps to cut down that add black stones")
        } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text("SNSなど、控えたいアプリを選べます。合計10分使うごとに、瓶の中で場所をとる黒い石が1つ増えます。",
                     tableName: "ScreenTime", comment: "Footer: what the black-stone lane does")
                Text("黒い石同士だけがまとまります。勉強時間には加算されず、積んだ粒も減りません。",
                     tableName: "ScreenTime", comment: "Footer: black stones never reduce study")
                Text("無料でもアプリ数は無制限です。")
            }
        }
    }

    private var detailsSection: some View {
        Section {
            Text("勉強アプリと控えたいアプリは別々に合計します。同じアプリを両方には登録できません。",
                 tableName: "ScreenTime", comment: "About recording: the two lanes are summed separately")
            Text("次にポモジェムを開くと、届いた記録を瓶に反映します。反映が遅れることがあります。")
            Text("一部のアプリは、OSが関連Webサイトの利用も含める場合があります。")
            Text("10分未満の端数は、日付の切り替わりや設定の変更・停止でリセットされます。タイマー中の二重加算を避けるため、勉強アプリの計測もいったん区切ります。")
            Text("アプリの選択、未取り込みの利用記録、黒い石は、このiPhoneだけに保存します。JSON書き出しや保存先の切り替えでは引き継ぎません。",
                 tableName: "ScreenTime", comment: "About recording: device-local data")
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
            VStack(alignment: .leading, spacing: 5) {
                Text("アプリの選択・未取り込みの利用記録・黒い石を削除し、自動記録を停止します。保存済みの勉強時間と粒は残ります。",
                     tableName: "ScreenTime", comment: "Footer under the full Screen Time reset")
                if controller.negativeGemCount > 0 {
                    Text("黒い石だけを片付けるときは、上の「黒い石を片付ける」を使います。アプリの選択はそのまま残ります。",
                         tableName: "ScreenTime", comment: "Footer: point to the lighter black-stone clear")
                }
            }
        }
    }

    private var monitoringStatusText: String {
        let learningOverLimit = !purchase.isPro
            && controller.configuration.learningSelection.applicationTokens.count
                > ScreenTimePolicy.freeLearningApplicationLimit
        return controller.learningPausedByTimer || learningOverLimit
            ? String(localized: "控えたいアプリだけ自動記録中", table: "ScreenTime",
                     comment: "Status: only the black-stone lane is recording")
            : "自動記録中"
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
        .accessibilityLabel(lane.chooseAppsLabel)
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
        guard validationMessage == nil, !controller.isSaving, !controller.isResetting else {
            leavesAfterSave = false
            return
        }
        let configuration = draft
        let isPro = purchase.isPro
        Task {
            do {
                try await controller.save(configuration: configuration, isPro: isPro)
                controller.clearLearningThemeRemovalNotice()
                draft = controller.configuration
                hasUserEdits = false
                if controller.monitoringError == nil {
                    // Say what the save switched on or off. A first setup that
                    // left recording off used to read 「保存しました」 and then
                    // never recorded anything.
                    let toast = ScreenTimeDraftPolicy.savedToast(for: configuration)
                    router.showToast(toast.text, symbol: toast.symbol)
                }
                if leavesAfterSave, isVisible { dismiss() }
                leavesAfterSave = false
            } catch {
                leavesAfterSave = false
                saveError = error.localizedDescription
            }
        }
    }

    private func clearBlackStones() {
        do {
            try controller.clearBlackStones()
            router.showToast(String(localized: "黒い石を片付けました", table: "ScreenTime",
                                    comment: "Toast: the black stones were cleared"),
                             symbol: "checkmark")
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func reset() {
        Task {
            do {
                try await controller.resetActivityData()
                controller.clearLearningThemeRemovalNotice()
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

    /// The draft after the picker's 反映. On a first setup — nothing chosen in
    /// either lane yet — picking apps also switches recording on: the switch
    /// is off by default, and a first save that kept it off stored everything
    /// and recorded nothing. A user who already has apps chosen keeps
    /// whatever they set the switch to. With exactly one theme, a learning
    /// selection also gets that theme as its destination.
    static func applying(
        _ selection: FamilyActivitySelection,
        toLearningLane isLearning: Bool,
        in draft: ScreenTimeConfiguration,
        authorized: Bool,
        onlyThemeID: UUID?
    ) -> ScreenTimeConfiguration {
        var result = draft
        let wasEmpty = draft.learningSelection.applicationTokens.isEmpty
            && draft.distractionSelection.applicationTokens.isEmpty
        if isLearning {
            result.learningSelection = selection
        } else {
            result.distractionSelection = selection
        }
        let picked = !selection.applicationTokens.isEmpty
        if !result.enabled, wasEmpty, picked, authorized {
            result.enabled = true
        }
        if isLearning, picked, result.themeID == nil, let onlyThemeID {
            result.themeID = onlyThemeID
        }
        return result
    }

    /// The toast after a save, stating the resulting status.
    static func savedToast(for configuration: ScreenTimeConfiguration) -> (text: String, symbol: String) {
        if configuration.enabled {
            return (String(localized: "保存しました。自動記録中です", table: "ScreenTime",
                           comment: "Toast after saving Screen Time settings with recording on"),
                    "checkmark")
        }
        let hasApps = !configuration.learningSelection.applicationTokens.isEmpty
            || !configuration.distractionSelection.applicationTokens.isEmpty
        return (String(localized: "保存しました。自動記録はオフです", table: "ScreenTime",
                       comment: "Toast after saving Screen Time settings with recording off"),
                hasApps ? "exclamationmark.circle" : "checkmark")
    }
}

private enum ScreenTimeSelectionLane: String, Identifiable {
    case learning
    case distraction

    var id: String { rawValue }
    /// Whole phrases per lane rather than a noun spliced into a sentence.
    var appsTitle: String {
        self == .learning
            ? String(localized: "勉強アプリ", table: "ScreenTime", comment: "Picker title: study apps")
            : String(localized: "控えたいアプリ", table: "ScreenTime", comment: "Picker title: apps to cut down")
    }
    var chooseAppsLabel: String {
        self == .learning
            ? String(localized: "勉強アプリを選ぶ", table: "ScreenTime", comment: "VoiceOver: open the study-app picker")
            : String(localized: "控えたいアプリを選ぶ", table: "ScreenTime", comment: "VoiceOver: open the picker for apps to cut down")
    }
}

private enum ScreenTimeSelectionValidation {
    static func message(
        selection: FamilyActivitySelection,
        otherSelection: FamilyActivitySelection,
        lane: ScreenTimeSelectionLane,
        isPro: Bool
    ) -> String? {
        if let blocking = blockingMessage(selection: selection, otherSelection: otherSelection) {
            return blocking
        }
        if exceedsFreeLimit(selection: selection, lane: lane, isPro: isPro) {
            return "無料では勉強アプリを5つまで選べます。5つ以下に減らしてください。Proでは無制限です。"
        }
        return nil
    }

    /// What no save could ever accept, so the picker keeps 反映 off for it.
    static func blockingMessage(
        selection: FamilyActivitySelection,
        otherSelection: FamilyActivitySelection
    ) -> String? {
        if !selection.categoryTokens.isEmpty || !selection.webDomainTokens.isEmpty {
            return "カテゴリやWebサイトは選べません。カテゴリを開き、アプリを1つずつ選んでください。"
        }
        if !selection.applicationTokens.isDisjoint(with: otherSelection.applicationTokens) {
            return String(localized: "同じアプリを勉強アプリと控えたいアプリの両方には登録できません。もう一方の選択から外してください。",
                          table: "ScreenTime", comment: "Validation: an app is in both lanes")
        }
        return nil
    }

    /// The free plan's learning limit is NOT blocking in the picker: the
    /// paywall cannot appear over this sheet, so blocking 反映 left a free user
    /// who picked a sixth app only キャンセル — and every pick lost. The
    /// settings screen keeps 保存 off over the limit and offers Pro there.
    static func exceedsFreeLimit(selection: FamilyActivitySelection, lane: ScreenTimeSelectionLane, isPro: Bool) -> Bool {
        lane == .learning && !isPro
            && selection.applicationTokens.count > ScreenTimePolicy.freeLearningApplicationLimit
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

    private var blockingMessage: String? {
        ScreenTimeSelectionValidation.blockingMessage(selection: selection, otherSelection: otherSelection)
    }

    private var noticeMessage: String? {
        if let blockingMessage { return blockingMessage }
        guard ScreenTimeSelectionValidation.exceedsFreeLimit(selection: selection, lane: lane, isPro: isPro) else {
            return nil
        }
        return String(localized: "無料で記録できる勉強アプリは5つまでです。このまま反映して、設定画面でProにするか、5つ以下に減らしてから保存してください。",
                      table: "ScreenTime", comment: "Picker notice: over the free learning-app limit; applying is still allowed")
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
            .navigationTitle(lane.appsTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("反映") {
                        guard blockingMessage == nil else { return }
                        onApply(selection)
                        dismiss()
                    }
                    .disabled(blockingMessage != nil)
                    .accessibilityIdentifier("screen-time.picker-apply")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(selection.applicationTokens.count)アプリ選択中")
                            .font(.subheadline.weight(.semibold))
                        if let noticeMessage {
                            Text(noticeMessage)
                                .font(.footnote)
                                .foregroundStyle(blockingMessage == nil ? PomoGemTheme.amber : .red)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("screen-time.picker-status")
#if DEBUG && targetEnvironment(simulator)
                    // FamilyActivityPicker hands out no tokens on the
                    // Simulator; the settings fixture stands in for it.
                    if ScreenTimeSettingsUITestFixture.isActiveForCurrentProcess {
                        Button("fixture-pick-apps") {
                            selection.applicationTokens = ScreenTimeSettingsUITestFixture.applicationTokens(
                                count: 2, seed: lane == .learning ? 0x51 : 0x52)
                        }
                        .font(.caption)
                        .accessibilityIdentifier("screen-time.fixture-pick-apps")
                    }
#endif
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.regularMaterial)
            }
        }
    }
}
