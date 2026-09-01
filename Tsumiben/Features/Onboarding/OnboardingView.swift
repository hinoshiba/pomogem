import SwiftData
import SwiftUI
import UIKit

struct OnboardingView: View {
    let onComplete: (Set<String>, Bool, UsagePurpose, RareRewardMode) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var trialDropped = false
    @State private var usagePurpose = UsagePurpose.study
    @State private var selectionsByPurpose: [UsagePurpose: Set<String>] = [
        .study: [],
        .work: []
    ]
    @State private var wantsNotifications = false
    @State private var selectedRareRewardMode: RareRewardMode?
    @Query(sort: \Subject.sortOrder) private var existingSubjects: [Subject]

    private let pageCount = 4

    var body: some View {
        ZStack {
            NightBackground()
            VStack(spacing: 0) {
                HStack {
                    TsumibenLogo(compact: true)
                    Spacer()
                    Text("\(page + 1) / \(pageCount)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(TsumibenTheme.muted)
                        .accessibilityLabel("全\(pageCount)ページ中、\(page + 1)ページ")
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)

                TabView(selection: pageSelection) {
                    ValuePage()
                    .tag(0)

                    TrialDropPage(dropped: $trialDropped)
                    .tag(1)

                    SubjectSetupPage(
                        usagePurpose: $usagePurpose,
                        selectedSubjects: activeSelections,
                        wantsNotifications: $wantsNotifications,
                        existingSubjectNames: Set(existingSubjects.map(\.name)),
                        availableNewSubjectSlots: availableNewSubjectSlots
                    )
                    .tag(2)

                    RareRewardOnboardingPage(selection: $selectedRareRewardMode)
                        .tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: page)

                VStack(spacing: 18) {
                    HStack(spacing: 7) {
                        ForEach(0..<pageCount, id: \.self) { index in
                            Capsule()
                                .fill(index == page ? TsumibenTheme.amber : TsumibenTheme.raised)
                                .frame(width: index == page ? 24 : 7, height: 7)
                                .animation(reduceMotion ? nil : .spring(response: 0.3), value: page)
                        }
                    }
                    .accessibilityHidden(true)

                    Button {
                        advance()
                    } label: {
                        Text(page == pageCount - 1 ? "瓶をひらく" : "次へ")
                    }
                    .buttonStyle(TsumibenPrimaryButtonStyle())
                    .disabled(isPrimaryActionDisabled)
                    .accessibilityHint(primaryActionHint)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
        }
    }

    private var pageSelection: Binding<Int> {
        Binding(
            get: { page },
            set: { nextPage in
                guard !(page == 1 && nextPage > page && !trialDropped) else { return }
                guard !(page == 2 && nextPage > page && currentSelections.isEmpty) else { return }
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
            guard let selectedRareRewardMode else { return }
            onComplete(
                currentSelections,
                wantsNotifications,
                usagePurpose,
                selectedRareRewardMode
            )
        }
    }

    private var isPrimaryActionDisabled: Bool {
        (page == 1 && !trialDropped)
            || (page == 2 && currentSelections.isEmpty)
            || (page == pageCount - 1 && selectedRareRewardMode == nil)
    }

    private var primaryActionHint: String {
        if page == 1, !trialDropped {
            return "ためしの一粒を積むと進めます"
        }
        if page == 2, currentSelections.isEmpty {
            return "カテゴリを1つ以上選ぶと瓶をひらけます"
        }
        if page == pageCount - 1, selectedRareRewardMode == nil {
            return "レア粒の扱いを1つ選ぶと瓶をひらけます"
        }
        return ""
    }

    private var currentSelections: Set<String> {
        selectionsByPurpose[usagePurpose] ?? []
    }

    /// The study presets are seeded before the first-use choice is known. In
    /// work mode, unused preset rows with no history are removed on completion
    /// and therefore must not consume the user's twelve active category slots.
    private var availableNewSubjectSlots: Int {
        let occupiedCount: Int
        if usagePurpose == .work {
            let studyPresetIDs = Set(SeedData.subjects.map(\.id))
            occupiedCount = existingSubjects.filter { subject in
                !studyPresetIDs.contains(subject.id)
                    || !(subject.studySessions?.isEmpty ?? true)
                    || !(subject.achievementStones?.isEmpty ?? true)
            }.count
        } else {
            occupiedCount = existingSubjects.count
        }
        return max(0, Constants.App.maximumSubjects - occupiedCount)
    }

    private var activeSelections: Binding<Set<String>> {
        Binding(
            get: { selectionsByPurpose[usagePurpose] ?? [] },
            set: { selectionsByPurpose[usagePurpose] = $0 }
        )
    }
}

private struct ValuePage: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                OnboardingJar(pebbleCount: 7)
                    .frame(height: jarHeight)
                VStack(spacing: 14) {
                    SectionEyebrow(text: "YOUR TIME, IN THE JAR")
                    Text("25分集中すると、1粒。")
                        .font(TsumibenTheme.brand(30))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(TsumibenTheme.text)
                        .accessibilityAddTraits(.isHeader)
                    Text("完走した集中時間が、瓶の中で手応えのある粒になります。")
                        .font(.body)
                        .foregroundStyle(TsumibenTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
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
                    ValuePromise(
                        symbol: "arrow.triangle.2.circlepath.icloud.fill",
                        title: "積み上げを引き継ぐ",
                        detail: "iCloudを有効にした同じApple Accountなら、iPhone間・機種変更後も同期"
                    )

                    Text("以前の瓶がある場合は、この画面を開いたままiCloudの反映を少しお待ちください。届くと自動で瓶が開きます。")
                        .font(.caption)
                        .foregroundStyle(TsumibenTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
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
}

private struct ValuePromise: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .foregroundStyle(TsumibenTheme.amber)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .bold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(TsumibenTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 14))
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
                            .stroke(TsumibenTheme.glassEdge, lineWidth: 2)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    if (reduceMotion || voiceOverEnabled), !dropped, !isDropping {
                        Text("着地演出は必須ではありません。記録を作らずに先へ進めます。")
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("演出を省略して進む", action: completeWithoutAnimation)
                            .buttonStyle(TsumibenPrimaryButtonStyle())
                        if !reduceMotion {
                            Button("着地演出を試す", action: startDrop)
                                .buttonStyle(TsumibenSecondaryButtonStyle())
                        }
                    } else if showsRecoveryActions, !dropped {
                        Text("着地を確認できませんでした。記録には影響しません。")
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("もう一度", action: startDrop)
                            .buttonStyle(TsumibenSecondaryButtonStyle())
                        Button("演出を省略して進む", action: completeWithoutAnimation)
                            .buttonStyle(TsumibenPrimaryButtonStyle())
                    } else {
                        Button(action: startDrop) {
                            Label(dropButtonTitle, systemImage: dropButtonSymbol)
                        }
                        .buttonStyle(TsumibenSecondaryButtonStyle())
                        .disabled(dropped || isDropping)
                        .accessibilityValue(isDropping ? "落下中" : dropped ? "着地済み" : "落下前")
                    }

                    Text("0g・記録には入りません")
                        .font(.caption)
                        .foregroundStyle(TsumibenTheme.muted)
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
        .onChange(of: reduceMotion) { _, enabled in
            guard enabled, isDropping, !dropped else { return }
            completeWithoutAnimation()
        }
        .task(id: activeDropID) {
            guard let expectedID = activeDropID,
                  isDropping,
                  !dropped,
                  !reduceMotion
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
        if reduceMotion {
            scene.restore(pebbles: [pebble])
            completeDrop(announcement: "一粒を積みました。次へ進めます")
        } else {
            isDropping = true
            scene.restore(pebbles: [])
            scene.drop(pebble)
        }
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
    @Binding var usagePurpose: UsagePurpose
    @Binding var selectedSubjects: Set<String>
    @Binding var wantsNotifications: Bool
    let existingSubjectNames: Set<String>
    let availableNewSubjectSlots: Int
    @State private var customSubjectName = ""
    @State private var customSubjectFeedback: String?

    private var presetNames: Set<String> {
        Set(usagePurpose.presets.map(\.name))
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
        return !requiresNewSubject(named: name) || remainingNewSubjectSlots > 0
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionEyebrow(text: "YOUR BOTTLE")
                    Text("何に使いますか？")
                        .font(TsumibenTheme.brand(30))
                    Text("目的に合わせて、最初のカテゴリ候補と言葉を整えます。どちらを選んでも後から変更できます。")
                        .font(.subheadline)
                        .foregroundStyle(TsumibenTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    ForEach(UsagePurpose.allCases) { purpose in
                        Button {
                            usagePurpose = purpose
                            customSubjectName = ""
                            customSubjectFeedback = nil
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: purpose.symbol)
                                    .foregroundStyle(
                                        usagePurpose == purpose
                                            ? TsumibenTheme.amber
                                            : TsumibenTheme.muted
                                    )
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(purpose.title)
                                        .font(.system(.body, design: .rounded, weight: .bold))
                                    Text(purpose.summary)
                                        .font(.caption)
                                        .foregroundStyle(TsumibenTheme.muted)
                                }
                                Spacer(minLength: 8)
                                Image(
                                    systemName: usagePurpose == purpose
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                                .foregroundStyle(
                                    usagePurpose == purpose
                                        ? TsumibenTheme.amber
                                        : TsumibenTheme.muted
                                )
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 62)
                            .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 15))
                            .overlay {
                                if usagePurpose == purpose {
                                    RoundedRectangle(cornerRadius: 15)
                                        .stroke(TsumibenTheme.amber.opacity(0.7), lineWidth: 1)
                                }
                            }
                        }
                        .buttonStyle(
                            TsumibenRowButtonStyle(
                                isSelected: usagePurpose == purpose,
                                cornerRadius: 15
                            )
                        )
                        .accessibilityValue(usagePurpose == purpose ? "選択中" : "未選択")
                        .accessibilityAddTraits(usagePurpose == purpose ? .isSelected : [])
                    }
                }

                if let privacyGuidance = usagePurpose.privacyGuidance {
                    VStack(alignment: .leading, spacing: 12) {
                        Label {
                            Text(privacyGuidance)
                                .font(.caption)
                                .foregroundStyle(TsumibenTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(TsumibenTheme.amber)
                        }
                        if let professionalUseGuidance = usagePurpose.professionalUseGuidance {
                            Divider()
                            Label {
                                Text(professionalUseGuidance)
                                    .font(.caption)
                                    .foregroundStyle(TsumibenTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                                    .foregroundStyle(TsumibenTheme.amber)
                            }
                        }
                    }
                    .padding(16)
                    .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityElement(children: .combine)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(usagePurpose.firstCategoryTitle)
                        .font(TsumibenTheme.brand(24))
                    Text(usagePurpose.setupDetail)
                        .font(.subheadline)
                        .foregroundStyle(TsumibenTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 10) {
                    ForEach(usagePurpose.presets) { preset in
                        Button {
                            togglePreset(preset)
                        } label: {
                            HStack(spacing: 14) {
                                Circle()
                                    .fill(Color(hex: preset.colorHex))
                                    .frame(width: 14, height: 14)
                                Text(preset.name)
                                    .font(.system(.body, design: .rounded, weight: .bold))
                                Spacer()
                                Image(systemName: selectedSubjects.contains(preset.name) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedSubjects.contains(preset.name) ? TsumibenTheme.amber : TsumibenTheme.muted)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 50)
                            .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 13))
                        }
                        .buttonStyle(TsumibenBareButtonStyle())
                        .accessibilityValue(selectedSubjects.contains(preset.name) ? "選択中" : "未選択")
                        .accessibilityAddTraits(
                            selectedSubjects.contains(preset.name) ? .isSelected : []
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(usagePurpose.customFieldTitle)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(TsumibenTheme.muted)
                    Text("新しく追加できるのはあと\(remainingNewSubjectSlots)件です（合計最大\(Constants.App.maximumSubjects)件）。既存のテーマを選び直す場合は枠を使いません。")
                        .font(.caption)
                        .foregroundStyle(TsumibenTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        TextField(usagePurpose.customFieldPlaceholder, text: $customSubjectName)
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
                            .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 13))
                        Button("追加", action: addCustomSubject)
                            .font(.subheadline.weight(.bold))
                            .frame(minWidth: 64, minHeight: 50)
                            .background(TsumibenTheme.raised, in: RoundedRectangle(cornerRadius: 13))
                            .buttonStyle(TsumibenBareButtonStyle())
                            .disabled(!canAddCustomSubject)
                    }

                    Text(customSubjectLengthMessage)
                        .font(.caption)
                        .foregroundStyle(customSubjectIsTooLong ? Color.red : TsumibenTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(customSubjectLengthMessage)

                    if let customSubjectFeedback {
                        Text(customSubjectFeedback)
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if remainingNewSubjectSlots == 0 {
                        Text("追加できる枠をすべて選びました。瓶をひらいた後も編集できます。")
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(customSubjects, id: \.self) { name in
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(TsumibenTheme.amber)
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
                            .buttonStyle(TsumibenBareButtonStyle())
                            .foregroundStyle(TsumibenTheme.muted)
                            .accessibilityLabel("\(name)を選択から外す")
                        }
                        .padding(.leading, 14)
                        .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 13))
                    }
                }

                Label(
                    selectedSubjects.isEmpty
                        ? "カテゴリを1つ以上選ぶと、瓶をひらけます"
                        : "\(selectedSubjects.count)件を選択中",
                    systemImage: selectedSubjects.isEmpty ? "circle" : "checkmark.circle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(selectedSubjects.isEmpty ? TsumibenTheme.muted : TsumibenTheme.amber)
                .fixedSize(horizontal: false, vertical: true)

                Toggle(isOn: $wantsNotifications) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("瓶からの通知")
                            .font(.system(.body, design: .rounded, weight: .bold))
                        Text(Constants.UIStrings.eveningNotification)
                            .font(.caption)
                            .foregroundStyle(TsumibenTheme.muted)
                    }
                }
                .tint(TsumibenTheme.amber)
                .padding(16)
                .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 16))

                Text("通知はあとから設定できます。赤いバッジや連続記録の警告は使いません。")
                    .font(.caption)
                    .foregroundStyle(TsumibenTheme.muted)
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 24)
            .padding(.top, 36)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func addCustomSubject() {
        if let customSubjectValidationError {
            showCustomSubjectFeedback(customSubjectValidationError.message)
            return
        }
        guard let name = SubjectNamePolicy.validated(customSubjectName) else { return }

        let normalized = SubjectNamePolicy.comparisonKey(name)
        if let preset = usagePurpose.presets.first(where: {
            SubjectNamePolicy.comparisonKey($0.name) == normalized
        }) {
            selectedSubjects.insert(preset.name)
            customSubjectName = ""
            showCustomSubjectFeedback("同じ名前の候補「\(preset.name)」を選択しました。")
            return
        }

        if let existing = customSubjects.first(where: {
            SubjectNamePolicy.comparisonKey($0) == normalized
        }) {
            customSubjectName = ""
            showCustomSubjectFeedback("「\(existing)」はすでに追加されています。")
            return
        }

        guard !requiresNewSubject(named: name) || remainingNewSubjectSlots > 0 else {
            showCustomSubjectFeedback("カテゴリは合計最大\(Constants.App.maximumSubjects)件です。不要なテーマは設定から削除できます。")
            return
        }

        selectedSubjects.insert(name)
        customSubjectName = ""
        customSubjectFeedback = nil
    }

    private func showCustomSubjectFeedback(_ message: String) {
        customSubjectFeedback = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func togglePreset(_ preset: UsagePurpose.CategoryPreset) {
        if selectedSubjects.contains(preset.name) {
            selectedSubjects.remove(preset.name)
            customSubjectFeedback = nil
            return
        }
        guard !requiresNewSubject(named: preset.name) || remainingNewSubjectSlots > 0 else {
            showCustomSubjectFeedback("追加できるテーマは合計最大\(Constants.App.maximumSubjects)件です。")
            return
        }
        selectedSubjects.insert(preset.name)
        customSubjectFeedback = nil
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
                    .font(TsumibenTheme.brand(27))
                    .foregroundStyle(TsumibenTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(introduction)
                    .font(.subheadline)
                    .foregroundStyle(TsumibenTheme.muted)
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
                                .foregroundStyle(TsumibenTheme.amber)
                                .frame(width: 28, height: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(mode.title)
                                    .font(.system(.body, design: .rounded, weight: .bold))
                                    .foregroundStyle(TsumibenTheme.text)
                                Text(choiceDetail(for: mode))
                                    .font(.caption)
                                    .foregroundStyle(TsumibenTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: selection == mode ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(selection == mode ? TsumibenTheme.amber : TsumibenTheme.muted)
                                .accessibilityHidden(true)
                        }
                        .padding(15)
                        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                        .background(TsumibenTheme.card, in: RoundedRectangle(cornerRadius: 16))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(
                                    selection == mode ? TsumibenTheme.amber : TsumibenTheme.raised,
                                    lineWidth: selection == mode ? 2 : 1
                                )
                        }
                    }
                    .buttonStyle(TsumibenBareButtonStyle())
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
            .background(TsumibenTheme.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
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
                .foregroundStyle(TsumibenTheme.amber)
                .frame(width: 19)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(TsumibenTheme.muted)
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
