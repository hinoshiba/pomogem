import SwiftData
import SwiftUI
import UIKit

struct OnboardingView: View {
    let persistenceMode: PersistenceLaunchMode
    let onComplete: (Set<String>, Bool, RareRewardMode) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var trialDropped = false
    @State private var selectedSubjects = Set<String>()
    @State private var wantsNotifications = false
    @State private var selectedRareRewardMode: RareRewardMode?
    @Environment(\.modelContext) private var modelContext
    /// Live theme rows only; tombstones never count toward the row bound.
    @Query(sort: \Subject.sortOrder) private var storedSubjects: [Subject]
    /// Observed so a deletion delivered as a new physical row refreshes the
    /// list; see `SubjectSyncPolicy.presentationSubjects(live:tombstones:context:)`.
    @Query private var storedSubjectTombstones: [Subject]

    init(
        persistenceMode: PersistenceLaunchMode = .inMemoryPreview,
        onComplete: @escaping (Set<String>, Bool, RareRewardMode) -> Void
    ) {
        self.persistenceMode = persistenceMode
        self.onComplete = onComplete
        _storedSubjects = Query(SubjectSyncPolicy.liveRowsDescriptor(sortBy: [
            SortDescriptor(\Subject.sortOrder),
            SortDescriptor(\Subject.syncRecordID)
        ]))
        _storedSubjectTombstones = Query(SubjectSyncPolicy.tombstoneRowsDescriptor())
    }

    private var pageCount: Int {
        RareRewardReleasePolicy.isEnabled ? 4 : 3
    }

    private var existingSubjects: [Subject] {
        SubjectSyncPolicy.presentationSubjects(
            live: storedSubjects, tombstones: storedSubjectTombstones, context: modelContext
        )
    }

    var body: some View {
        ZStack {
            NightBackground()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if page == 0 {
                        PomoGemLogo(compact: true)
                    } else {
                        Button(action: retreat) {
                            Label("戻る", systemImage: "chevron.left")
                                .font(.subheadline.weight(.semibold))
                                .frame(minWidth: 68, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PomoGemCompactButtonStyle(tint: PomoGemTheme.text, isProminent: false))
                        .accessibilityLabel("戻る")
                        .accessibilityHint("選んだ内容を保ったまま、前のページへ戻ります")
                        .accessibilityIdentifier("onboarding.back")
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(stepTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PomoGemTheme.text)
                        Text("\(page + 1) / \(pageCount)")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("全\(pageCount)ページ中、\(page + 1)ページ。\(stepTitle)")
                    .accessibilityIdentifier("onboarding.step")
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 24)
                .padding(.top, 12)

                TabView(selection: pageSelection) {
                    ValuePage(persistenceMode: persistenceMode)
                    .tag(0)

                    TrialDropPage(dropped: $trialDropped)
                    .tag(1)

                    SubjectSetupPage(
                        selectedSubjects: $selectedSubjects,
                        wantsNotifications: $wantsNotifications,
                        existingSubjectNames: Set(existingSubjects.map(\.name)),
                        availableNewSubjectSlots: availableNewSubjectSlots
                    )
                    .tag(2)

                    if RareRewardReleasePolicy.isEnabled {
                        RareRewardOnboardingPage(selection: $selectedRareRewardMode)
                            .tag(3)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: page)

                VStack(spacing: 12) {
                    HStack(spacing: 7) {
                        ForEach(0..<pageCount, id: \.self) { index in
                            Capsule()
                                .fill(index == page ? PomoGemTheme.amber : PomoGemTheme.raised)
                                .frame(width: index == page ? 24 : 7, height: 7)
                                .animation(reduceMotion ? nil : .spring(response: 0.3), value: page)
                        }
                    }
                    .accessibilityHidden(true)

                    if page == 2 {
                        Text(
                            selectedSubjects.isEmpty
                                ? "テーマを1つ選ぶと、瓶をひらけます"
                                : "最初のテーマ：\(selectedSubjects.sorted().first ?? "選択済み")"
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selectedSubjects.isEmpty ? PomoGemTheme.muted : PomoGemTheme.amber)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding.selection-summary")
                    }

                    Button {
                        advance()
                    } label: {
                        Text(page == pageCount - 1 ? "瓶をひらく" : "次へ")
                    }
                    .buttonStyle(PomoGemPrimaryButtonStyle())
                    .disabled(isPrimaryActionDisabled)
                    .accessibilityHint(primaryActionHint)
                    .accessibilityIdentifier("onboarding.next")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
        }
    }

    private var stepTitle: String {
        switch page {
        case 0: "集中が残るしくみ"
        case 1: "一粒を体験（任意）"
        case 2: "最初のテーマ"
        default: "粒の好み"
        }
    }

    private func retreat() {
        guard page > 0 else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            page -= 1
        }
    }

    private var pageSelection: Binding<Int> {
        Binding(
            get: { page },
            set: { nextPage in
                guard !(page == 2 && nextPage > page && selectedSubjects.isEmpty) else { return }
                page = nextPage
            }
        )
    }

    private func advance() {
        guard !isPrimaryActionDisabled else { return }
        if page < pageCount - 1 {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                page += 1
            }
        } else {
            let resolvedRareRewardMode: RareRewardMode
            if RareRewardReleasePolicy.isEnabled {
                guard let selectedRareRewardMode else { return }
                resolvedRareRewardMode = selectedRareRewardMode
            } else {
                resolvedRareRewardMode = .off
            }
            onComplete(
                selectedSubjects,
                wantsNotifications,
                resolvedRareRewardMode
            )
        }
    }

    private var isPrimaryActionDisabled: Bool {
        (page == 2 && selectedSubjects.isEmpty)
            || (RareRewardReleasePolicy.isEnabled
                && page == pageCount - 1
                && selectedRareRewardMode == nil)
    }

    private var primaryActionHint: String {
        if page == 2, selectedSubjects.isEmpty {
            return "テーマを1つ選ぶと瓶をひらけます"
        }
        if RareRewardReleasePolicy.isEnabled,
           page == pageCount - 1,
           selectedRareRewardMode == nil {
            return "レア粒の扱いを1つ選ぶと瓶をひらけます"
        }
        switch page {
        case 0:
            return "次は、記録を作らず一粒を試せるページです"
        case 1:
            return "体験を省略して、最初のテーマを選べます"
        case 2 where !RareRewardReleasePolicy.isEnabled:
            return "ホームへ進みます。テーマと時間を確認してから集中を始められます"
        default:
            return "次のページへ進みます"
        }
    }

    /// Built-in learning presets can exist before first-use setup is complete.
    /// Unselected presets without history are reclaimed on completion and must
    /// not consume one of the user's twelve theme slots here.
    private var availableNewSubjectSlots: Int {
        let builtInIDs = Set(SeedData.subjects.map(\.id))
        let occupiedCount = existingSubjects.filter { subject in
            OnboardingThemePolicy.countsAgainstThemeLimitBeforeSelection(
                isBuiltInPreset: builtInIDs.contains(subject.id),
                hasHistory: !(subject.studySessions?.isEmpty ?? true)
                    || !(subject.achievementStones?.isEmpty ?? true)
            )
        }.count
        return max(0, Constants.App.maximumSubjects - occupiedCount)
    }
}

private struct ValuePage: View {
    let persistenceMode: PersistenceLaunchMode

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isCloudOfflineSession) private var isCloudOffline
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                OnboardingJar(pebbleCount: 7)
                    .frame(height: jarHeight)
                VStack(spacing: 14) {
                    SectionEyebrow(text: "YOUR TIME, IN THE JAR")
                    Text("集中を終えると、一粒。")
                        .font(PomoGemTheme.brand(30))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(PomoGemTheme.text)
                        .accessibilityAddTraits(.isHeader)
                    Text("テーマと時間を選んで、集中をはじめる。\n完走すると、その時間が一粒になって残ります。")
                        .font(.body)
                        .foregroundStyle(PomoGemTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("25・45・60・90分のタイマーは無料", systemImage: "timer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.amber)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding.free-timers")
                }

                VStack(spacing: 10) {
                    ValuePromise(
                        symbol: "archivebox.fill",
                        title: "減らない",
                        detail: "積んだ粒と記録は、そのまま残る"
                    )
                    ValuePromise(
                        symbol: "leaf.fill",
                        title: "責めない",
                        detail: "できない日があっても、警告や罰はない"
                    )

                    // product-01 / launch-04. The storage choice was made
                    // seconds ago and confirmed with its full caveats; this
                    // page no longer repeats it a third time. Only an iCloud
                    // session keeps one caption, because it says something
                    // this moment needs.
                    if let storageDetail {
                        Text(storageDetail)
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .accessibilityIdentifier("onboarding.storage-detail")
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var jarHeight: CGFloat {
        verticalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize ? 180 : 250
    }

    private var storageDetail: String? {
        guard persistenceMode == .cloudKit else { return nil }
        if isCloudOffline {
            return "現在は端末に保存済みのデータを使っています。まだ届いていないiCloudのデータは、接続回復後に確認します。"
        }
        return "以前の瓶がある場合は、この画面を開いたままiCloudの反映を少しお待ちください。届くと自動で瓶が開きます。"
    }
}

private struct ValuePromise: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .foregroundStyle(PomoGemTheme.amber)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .bold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingJar: View {
    let pebbleCount: Int

    private let colors: [Color] = [
        Color("subj.eng"), Color("subj.math"), Color("subj.sci"),
        Color("subj.jpn"), Color("subj.soc"), Color("pebble.gold")
    ]

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.68, 230)
            let height = min(proxy.size.height, 330)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.025), Color("subj.math").opacity(0.055)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .stroke(PomoGemTheme.glassEdge, lineWidth: 2)
                    }
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom))
                            .frame(width: 7, height: height * 0.52)
                            .padding(.leading, 15)
                    }

                ZStack {
                    ForEach(0..<pebbleCount, id: \.self) { index in
                        OnboardingPebble(
                            color: colors[index % colors.count],
                            x: CGFloat((index % 4) * 39) - 58 + CGFloat((index / 4) % 2) * 18,
                            y: -CGFloat(index / 4) * 32
                        )
                    }
                }
                .padding(.bottom, 12)
            }
            .frame(width: width, height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .shadow(color: Color("subj.math").opacity(0.12), radius: 44)
        }
        .accessibilityHidden(true)
    }
}

private struct OnboardingPebble: View {
    let color: Color
    let x: CGFloat
    let y: CGFloat

    var body: some View {
        Circle()
            .fill(color)
            .overlay(alignment: .topLeading) {
                Capsule().fill(.white.opacity(0.34)).frame(width: 8, height: 4).padding(7)
            }
            .shadow(color: color.opacity(0.2), radius: 7)
            .frame(width: 36, height: 36)
            .offset(x: x, y: y)
    }
}

private struct TrialDropPage: View {
    @Binding var dropped: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var scene = JarScene(size: CGSize(width: 240, height: 320))
    @State private var isDropping = false
    @State private var activeDropID: UUID?
    @State private var showsRecoveryActions = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                SectionEyebrow(text: "THE FIRST DROP")
                JarSpriteView(scene: scene, totalGrams: 0, pebbleCount: dropped ? 1 : 0)
                    .frame(width: 240, height: jarHeight)
                    .shadow(color: Color("subj.math").opacity(0.12), radius: 45)
                    .accessibilityLabel(jarAccessibilityLabel)
                    .accessibilityValue(jarAccessibilityValue)
                    .accessibilityHint(
                        dropped
                            ? "一粒目の着地が完了しました"
                            : "下のボタンで、ためしの一粒を落とせます"
                    )

                VStack(spacing: 12) {
                    if voiceOverEnabled, !dropped, !isDropping {
                        Text("ためしの一粒は任意です。記録を作らず、「次へ」でそのまま進めます。")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("動きを使わず一粒を試す", action: completeWithoutAnimation)
                            .buttonStyle(PomoGemPrimaryButtonStyle())
                        Button("着地演出を試す", action: startDrop)
                            .buttonStyle(PomoGemSecondaryButtonStyle())
                    } else if showsRecoveryActions, !dropped {
                        Text("着地を確認できませんでした。記録には影響しません。")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("もう一度", action: startDrop)
                            .buttonStyle(PomoGemSecondaryButtonStyle())
                        Button("動きを使わず一粒を試す", action: completeWithoutAnimation)
                            .buttonStyle(PomoGemPrimaryButtonStyle())
                    } else {
                        Button(action: startDrop) {
                            Label(dropButtonTitle, systemImage: dropButtonSymbol)
                        }
                        .buttonStyle(PomoGemSecondaryButtonStyle())
                        .disabled(dropped || isDropping)
                        .accessibilityValue(isDropping ? "落下中" : dropped ? "着地済み" : "落下前")
                    }

                    Text("任意の体験です。0g・記録には入りません。「次へ」で省略できます。")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            scene.onLanding = { event in
                guard event.pebble.isTutorial,
                      event.pebble.id == activeDropID
                else { return }
                completeDrop(announcement: "一粒、着地しました。次へ進めます")
            }
            scene.configureBase(strata: [], bedrock: nil, showsMonthLabels: false)
        }
        .task(id: activeDropID) {
            guard let expectedID = activeDropID,
                  isDropping,
                  !dropped
            else { return }
            try? await Task.sleep(for: .milliseconds(2_500))
            guard !Task.isCancelled,
                  activeDropID == expectedID,
                  isDropping,
                  !dropped
            else { return }
            isDropping = false
            showsRecoveryActions = true
            UIAccessibility.post(
                notification: .announcement,
                argument: "着地を確認できませんでした。もう一度試すか、演出を省略して進めます"
            )
        }
    }

    private var jarHeight: CGFloat {
        verticalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize ? 220 : 320
    }

    private func startDrop() {
        guard !dropped, !isDropping else { return }
        showsRecoveryActions = false
        let pebble = tutorialPebble()
        activeDropID = pebble.id
        isDropping = true
        scene.restore(pebbles: [])
        scene.drop(pebble)
    }

    private func completeWithoutAnimation() {
        guard !dropped else { return }
        let pebble = tutorialPebble()
        activeDropID = pebble.id
        scene.restore(pebbles: [pebble])
        completeDrop(announcement: "演出を省略して一粒を積みました。次へ進めます")
    }

    private func completeDrop(announcement: String) {
        isDropping = false
        showsRecoveryActions = false
        activeDropID = nil
        guard !dropped else { return }
        dropped = true
        UIAccessibility.post(notification: .announcement, argument: announcement)
    }

    private func tutorialPebble() -> PebbleDescriptor {
        PebbleDescriptor(
            subjectName: "ためし積み",
            colorHex: Constants.Color.glassEdge,
            source: .timer,
            kind: .normal,
            grams: 0,
            isTutorial: true
        )
    }

    private var dropButtonTitle: String {
        if dropped { return "一粒、積もった" }
        if isDropping { return "一粒が落下中" }
        return "ためしに一粒、落としてみる"
    }

    private var dropButtonSymbol: String {
        if dropped { return "checkmark" }
        if isDropping { return "hourglass" }
        return "arrow.down"
    }

    private var jarAccessibilityLabel: String {
        if dropped { return "透明な一粒が瓶に積もりました" }
        if isDropping { return "透明な一粒が瓶の中を落下しています" }
        return "空の瓶"
    }

    private var jarAccessibilityValue: String {
        if dropped { return "1粒、0グラム" }
        if isDropping { return "落下中" }
        return "0粒、0グラム"
    }
}

private struct SubjectSetupPage: View {
    @Binding var selectedSubjects: Set<String>
    @Binding var wantsNotifications: Bool
    let existingSubjectNames: Set<String>
    let availableNewSubjectSlots: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var customSubjectName = ""
    @State private var customSubjectFeedback: String?
    @FocusState private var customSubjectFocused: Bool

    private var presetNames: Set<String> {
        Set(SubjectSuggestionCatalog.presets.map(\.name))
    }

    private var customSubjects: [String] {
        selectedSubjects.subtracting(presetNames).sorted()
    }

    private var existingSubjectKeys: Set<String> {
        Set(existingSubjectNames.map(SubjectNamePolicy.comparisonKey))
    }

    private var selectedNewSubjectCount: Int {
        selectedSubjects.reduce(into: 0) { count, name in
            if !existingSubjectKeys.contains(SubjectNamePolicy.comparisonKey(name)) {
                count += 1
            }
        }
    }

    private var remainingNewSubjectSlots: Int {
        max(0, availableNewSubjectSlots - selectedNewSubjectCount)
    }

    private var canAddCustomSubject: Bool {
        guard customSubjectValidationError == nil,
              let name = SubjectNamePolicy.validated(customSubjectName)
        else { return false }
        return canChooseSubject(named: name)
    }

    private var customSubjectValidationError: SubjectNamePolicy.ValidationError? {
        SubjectNamePolicy.validationError(for: customSubjectName)
    }

    private var customSubjectIsTooLong: Bool {
        guard let customSubjectValidationError else { return false }
        if case .tooLong = customSubjectValidationError { return true }
        return false
    }

    private var customSubjectLengthMessage: String {
        if customSubjectIsTooLong, let customSubjectValidationError {
            return customSubjectValidationError.message
        }
        if SubjectNamePolicy.trimmed(customSubjectName).isEmpty {
            return "最大\(SubjectNamePolicy.maximumCharacters)文字"
        }
        return "あと\(SubjectNamePolicy.remainingCharacters(for: customSubjectName))文字入力できます"
    }

    private var suggestionColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionEyebrow(text: "YOUR BOTTLE")
                    Text("最初のテーマを選ぶ")
                        .font(PomoGemTheme.brand(30))
                    Text(SubjectSuggestionCatalog.setupDetail)
                        .font(.subheadline)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("このあとはホームで時間を選び、開始ボタンをタップ。テーマはいつでも変更できます。")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("候補から選ぶ")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.muted)
                    Text("あとで設定から追加・編集できます。")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(columns: suggestionColumns, spacing: 10) {
                    ForEach(SubjectSuggestionCatalog.presets) { preset in
                        let isSelected = selectedSubjects.contains(preset.name)
                        Button {
                            choosePreset(preset)
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(Color(hex: preset.colorHex))
                                    .frame(width: 14, height: 14)
                                Text(preset.name)
                                    .font(.system(.body, design: .rounded, weight: .bold))
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? PomoGemTheme.amber : PomoGemTheme.muted)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 50)
                            .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 13))
                        }
                        .buttonStyle(
                            PomoGemRowButtonStyle(
                                isSelected: isSelected,
                                cornerRadius: 13
                            )
                        )
                        .disabled(!canChooseSubject(named: preset.name))
                        .accessibilityValue(isSelected ? "選択中" : "未選択")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("自由に入力")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.muted)
                    Text("新しく追加できるのはあと\(remainingNewSubjectSlots)件です（合計最大\(Constants.App.maximumSubjects)件）。")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        TextField(SubjectSuggestionCatalog.inputPlaceholder, text: $customSubjectName)
                            .focused($customSubjectFocused)
                            .textInputAutocapitalization(.never)
                            .submitLabel(.done)
                            .onSubmit(addCustomSubject)
                            .onChange(of: customSubjectName) { _, newValue in
                                if !newValue.isEmpty {
                                    customSubjectFeedback = nil
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 50)
                            .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 13))
                        Button("選択", action: addCustomSubject)
                            .font(.subheadline.weight(.bold))
                            .frame(minWidth: 64, minHeight: 50)
                            .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 13))
                            .buttonStyle(PomoGemBareButtonStyle())
                            .disabled(!canAddCustomSubject)
                    }

                    Text(customSubjectLengthMessage)
                        .font(.caption)
                        .foregroundStyle(customSubjectIsTooLong ? Color.red : PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(customSubjectLengthMessage)

                    if let customSubjectFeedback {
                        Text(customSubjectFeedback)
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if remainingNewSubjectSlots == 0 {
                        Text("新しいテーマの枠がありません。既存のテーマを選ぶか、瓶をひらいた後に整理してください。")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(customSubjects, id: \.self) { name in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(PomoGemTheme.amber)
                            Text(name)
                                .font(.system(.body, design: .rounded, weight: .bold))
                            Spacer()
                            Button {
                                selectedSubjects.remove(name)
                                customSubjectFeedback = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(PomoGemBareButtonStyle())
                            .foregroundStyle(PomoGemTheme.muted)
                            .accessibilityLabel("\(name)を選択から外す")
                        }
                        .padding(.leading, 14)
                        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 13))
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label {
                        Text(SubjectSuggestionCatalog.privacyGuidance)
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(PomoGemTheme.amber)
                    }
                    Divider()
                    Label {
                        Text(SubjectSuggestionCatalog.professionalUseGuidance)
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .foregroundStyle(PomoGemTheme.amber)
                    }
                }
                .padding(16)
                .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .combine)

                Toggle(isOn: $wantsNotifications) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("毎日のリマインダー")
                            .font(.system(.body, design: .rounded, weight: .bold))
                        Text("\(reminderTimeText)に、集中を思い出す通知を受け取る")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(PomoGemTheme.amber)
                .padding(16)
                .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("onboarding.daily-reminder")

                Text("通知は任意です。時刻やオン・オフは設定で変更できます。タイマーの終了通知は、このリマインダーとは別に、最初に集中を始めるときに一度だけ許可をおたずねします。")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 24)
            .padding(.top, 36)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }

    private var reminderTimeText: String {
        String(
            format: "%02d:%02d",
            Constants.Notification.defaultReminderHour,
            Constants.Notification.defaultReminderMinute
        )
    }

    private func addCustomSubject() {
        if let customSubjectValidationError {
            showCustomSubjectFeedback(customSubjectValidationError.message)
            return
        }
        guard let name = SubjectNamePolicy.validated(customSubjectName) else { return }

        let normalized = SubjectNamePolicy.comparisonKey(name)
        if let preset = SubjectSuggestionCatalog.preset(named: name) {
            selectedSubjects = [preset.name]
            customSubjectName = ""
            customSubjectFocused = false
            showCustomSubjectFeedback("同じ名前の候補「\(preset.name)」を選択しました。")
            return
        }

        if let existing = customSubjects.first(where: {
            SubjectNamePolicy.comparisonKey($0) == normalized
        }) {
            customSubjectName = ""
            customSubjectFocused = false
            showCustomSubjectFeedback("「\(existing)」を選択しています。")
            return
        }

        guard canChooseSubject(named: name) else {
            showCustomSubjectFeedback("テーマは合計最大\(Constants.App.maximumSubjects)件です。不要なテーマは設定から削除できます。")
            return
        }

        selectedSubjects = [name]
        customSubjectName = ""
        customSubjectFeedback = nil
        customSubjectFocused = false
    }

    private func showCustomSubjectFeedback(_ message: String) {
        customSubjectFeedback = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func choosePreset(_ preset: UsagePurpose.CategoryPreset) {
        guard canChooseSubject(named: preset.name) else {
            showCustomSubjectFeedback("追加できるテーマは合計最大\(Constants.App.maximumSubjects)件です。")
            return
        }
        selectedSubjects = [preset.name]
        customSubjectName = ""
        customSubjectFeedback = nil
        customSubjectFocused = false
    }

    private func canChooseSubject(named name: String) -> Bool {
        !requiresNewSubject(named: name)
            || remainingNewSubjectSlots > 0
            || selectedNewSubjectCount > 0
    }

    private func requiresNewSubject(named name: String) -> Bool {
        !existingSubjectKeys.contains(SubjectNamePolicy.comparisonKey(name))
    }
}

private struct RareRewardOnboardingPage: View {
    @Binding var selection: RareRewardMode?

    var body: some View {
        ScrollView {
            RareRewardChoicePanel(
                selection: $selection,
                eyebrow: "OPTIONAL VARIATION",
                title: "レア粒は、自分で選ぶ。",
                introduction: "どれを選んでも、質量・粒の融合・結晶・成果・使える機能は同じです。ランダムな結果を使わない「抽選しない」が安全な基準です。"
            )
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("onboarding.rare-reward-choice")
    }
}

/// A single, reusable informed-choice surface for onboarding and the legacy
/// pre-focus gate. Every option uses the same card, typography, and hit area;
/// no animation, color, or default checkmark nudges a person toward a draw.
struct RareRewardChoicePanel: View {
    @Binding var selection: RareRewardMode?
    let eyebrow: String
    let title: String
    let introduction: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                SectionEyebrow(text: eyebrow)
                Text(title)
                    .font(PomoGemTheme.brand(27))
                    .foregroundStyle(PomoGemTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(introduction)
                    .font(.subheadline)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rare-reward.equal-outcomes")
            }

            VStack(spacing: 10) {
                ForEach(RareRewardMode.choiceOrder) { mode in
                    Button {
                        selection = mode
                    } label: {
                        HStack(alignment: .top, spacing: 13) {
                            Image(systemName: mode.systemImage)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(PomoGemTheme.amber)
                                .frame(width: 28, height: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(mode.title)
                                    .font(.system(.body, design: .rounded, weight: .bold))
                                    .foregroundStyle(PomoGemTheme.text)
                                Text(choiceDetail(for: mode))
                                    .font(.caption)
                                    .foregroundStyle(PomoGemTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: selection == mode ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(selection == mode ? PomoGemTheme.amber : PomoGemTheme.muted)
                                .accessibilityHidden(true)
                        }
                        .padding(15)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(
                                    selection == mode ? PomoGemTheme.amber : PomoGemTheme.raised,
                                    lineWidth: selection == mode ? 2 : 1
                                )
                        }
                    }
                    .buttonStyle(PomoGemBareButtonStyle())
                    .accessibilityLabel(mode.title)
                    .accessibilityValue(selection == mode ? "選択中" : "未選択")
                    .accessibilityHint(choiceDetail(for: mode))
                    .accessibilityAddTraits(selection == mode ? .isSelected : [])
                    .accessibilityIdentifier("rare-reward.choice.\(mode.rawValue)")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                disclosureRow(
                    symbol: "equal.circle.fill",
                    text: "全モードで、1回の完走が積む質量と、粒の融合・結晶の進み方は同じ"
                )
                disclosureRow(
                    symbol: "percent",
                    text: "抽選する場合の自然確率：いつもの粒 \(GachaEngine.probabilityLabel(for: .normal))、金 \(GachaEngine.probabilityLabel(for: .gold))、虹 \(GachaEngine.probabilityLabel(for: .prism))"
                )
                disclosureRow(
                    symbol: "checkmark.shield.fill",
                    text: "実測タイマーで250g積むごとに1抽選。端数は次回へ繰り越します。\(GachaEngine.goldGuaranteeDisclosure)"
                )
                disclosureRow(
                    symbol: "gearshape.fill",
                    text: "あとから設定で変更できます。抽選しない間は乱数を使わず、その間の質量も抽選用には貯めません。既存の端数と保証カウントは停止します"
                )
            }
            .padding(15)
            .background(PomoGemTheme.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func choiceDetail(for mode: RareRewardMode) -> String {
        switch mode {
        case .off:
            "通常の粒だけを積みます。抽選せず、抽選用の端数と金の保証カウントも動かしません。"
        case .quiet:
            "金・虹の種類は履歴に残しますが、追加の発光・専用音・専用触覚は使いません。"
        case .standard:
            "確率と質量は控えめと同じ。金・虹に追加の発光・専用音・専用触覚を使います。"
        }
    }

    private func disclosureRow(symbol: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(PomoGemTheme.amber)
                .frame(width: 19)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("rare-reward.disclosure.\(symbol)")
    }
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(clean, radix: 16) ?? 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
