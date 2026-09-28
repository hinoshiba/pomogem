import SwiftData
import SwiftUI
import UIKit

struct OnboardingView: View {
    let persistenceMode: PersistenceLaunchMode
    /// launch-06. The user chose 「新しく始める」 over the iCloud restore
    /// screen, so page 1 must not ask them to wait after all.
    let startedFreshOverRestore: Bool
    let onComplete: (Set<String>, Bool, RareRewardMode) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var page = 0
    @State private var trialDropped = false
    @State private var selectedSubjects = Set<String>()
    /// launch-07. The theme-name field lives here, not in the page, so the
    /// primary button can use a valid name the user typed but did not commit
    /// with 「選択」 or Return (see `OnboardingThemePolicy.effectiveSelection`).
    @State private var pendingSubjectName = ""
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
        startedFreshOverRestore: Bool = false,
        onComplete: @escaping (Set<String>, Bool, RareRewardMode) -> Void
    ) {
        self.persistenceMode = persistenceMode
        self.startedFreshOverRestore = startedFreshOverRestore
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
        // Read once per render. The theme field lives in this view, so every
        // keystroke renders it again; each read walks the theme list.
        let themeLimit = themeLimitSnapshot
        let selection = effectiveSelectedSubjects(within: themeLimit)
        ZStack {
            NightBackground()
            VStack(spacing: 0) {
                // walk-edge-04 / walk-edge-10. These bars sit outside the
                // scrolling pages, so at accessibility sizes they must stay
                // small or they leave the page a sliver of the screen: the
                // back button becomes icon-only (its label, hint and Large
                // Content Viewer still say 戻る), the step title is left to
                // the page heading and VoiceOver, and the logo is capped.
                HStack(spacing: 12) {
                    if page == 0 {
                        PomoGemLogo(compact: true)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    } else {
                        Button(action: retreat) {
                            Group {
                                if usesCompactChrome {
                                    Label(backTitle, systemImage: "chevron.left")
                                        .labelStyle(.iconOnly)
                                        .frame(minWidth: 44, minHeight: 44)
                                } else {
                                    Label(backTitle, systemImage: "chevron.left")
                                        .lineLimit(1)
                                        .fixedSize()
                                        .frame(minWidth: 68, minHeight: 44, alignment: .leading)
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PomoGemCompactButtonStyle(tint: PomoGemTheme.text, isProminent: false))
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        .accessibilityLabel(backTitle)
                        .accessibilityHint(Text("選んだ内容を保ったまま、前のページへ戻ります", tableName: "Onboarding",
                                                comment: "VoiceOver hint for the onboarding back button"))
                        .accessibilityShowsLargeContentViewer {
                            Label(backTitle, systemImage: "chevron.left")
                        }
                        .accessibilityIdentifier("onboarding.back")
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        if !usesCompactChrome {
                            Text(stepTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PomoGemTheme.text)
                        }
                        // Digits only: the same in every language, never a catalog key.
                        Text(verbatim: "\(page + 1) / \(pageCount)")
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundStyle(PomoGemTheme.muted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("全\(pageCount)ページ中、\(page + 1)ページ。\(stepTitle)", tableName: "Onboarding",
                                             comment: "VoiceOver: onboarding progress; %1$lld pages in all, %2$lld the current page, %3$@ its title"))
                    .accessibilityIdentifier("onboarding.step")
                }
                .frame(minHeight: 44)
                .padding(.horizontal, 24)
                .padding(.top, 12)

                TabView(selection: pageSelection) {
                    ValuePage(
                        persistenceMode: persistenceMode,
                        startedFreshOverRestore: startedFreshOverRestore
                    )
                    .tag(0)

                    TrialDropPage(dropped: $trialDropped)
                    .tag(1)

                    SubjectSetupPage(
                        selectedSubjects: $selectedSubjects,
                        customSubjectName: $pendingSubjectName,
                        wantsNotifications: $wantsNotifications,
                        effectiveSelection: selection,
                        showsSelectionSummary: usesCompactChrome,
                        existingSubjectNames: themeLimit.existingNames,
                        availableNewSubjectSlots: themeLimit.availableNewSubjectSlots
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
                    // At accessibility sizes only the primary button stays
                    // pinned: the dots are decoration (already hidden from
                    // VoiceOver) and the theme summary moves into the page.
                    if !usesCompactChrome {
                        HStack(spacing: 7) {
                            ForEach(0..<pageCount, id: \.self) { index in
                                Capsule()
                                    .fill(index == page ? PomoGemTheme.amber : PomoGemTheme.raised)
                                    .frame(width: index == page ? 24 : 7, height: 7)
                                    .animation(reduceMotion ? nil : .spring(response: 0.3), value: page)
                            }
                        }
                        .accessibilityHidden(true)
                    }

                    if page == 2, !usesCompactChrome {
                        OnboardingSelectionSummary(selection: selection)
                    }

                    Button {
                        advance()
                    } label: {
                        Text(page == pageCount - 1 ? openJarTitle : nextTitle)
                    }
                    .buttonStyle(PomoGemPrimaryButtonStyle())
                    .disabled(isPrimaryActionDisabled(selection: selection))
                    .accessibilityHint(primaryActionHint(selection: selection))
                    .accessibilityIdentifier("onboarding.next")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
            }
        }
    }

    private var usesCompactChrome: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var backTitle: String {
        String(localized: "戻る", table: "Onboarding", comment: "Onboarding: back to the previous page")
    }

    private var nextTitle: String {
        String(localized: "次へ", table: "Onboarding", comment: "Onboarding: next page")
    }

    private var openJarTitle: String {
        String(localized: "瓶をひらく", table: "Onboarding", comment: "Onboarding: the last page's button, which finishes setup and opens the jar")
    }

    private var stepTitle: String {
        switch page {
        case 0: String(localized: "集中が残るしくみ", table: "Onboarding", comment: "Onboarding step 1 title: how your focus is kept")
        case 1: String(localized: "一粒を体験（任意）", table: "Onboarding", comment: "Onboarding step 2 title: try dropping one gem (optional)")
        case 2: String(localized: "最初のテーマ", table: "Onboarding", comment: "Onboarding step 3 title: your first theme")
        default: String(localized: "粒の好み", table: "Onboarding", comment: "Onboarding step 4 title: rare gem preference")
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
                guard !(page == 2 && nextPage > page
                        && effectiveSelectedSubjects(within: themeLimitSnapshot).isEmpty) else { return }
                page = nextPage
            }
        )
    }

    private func advance() {
        let selection = effectiveSelectedSubjects(within: themeLimitSnapshot)
        guard !isPrimaryActionDisabled(selection: selection) else { return }
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
                selection,
                wantsNotifications,
                resolvedRareRewardMode
            )
        }
    }

    private func isPrimaryActionDisabled(selection: Set<String>) -> Bool {
        (page == 2 && selection.isEmpty)
            || (RareRewardReleasePolicy.isEnabled
                && page == pageCount - 1
                && selectedRareRewardMode == nil)
    }

    private func primaryActionHint(selection: Set<String>) -> String {
        if page == 2, selection.isEmpty {
            return String(localized: "テーマを1つ選ぶと瓶をひらけます", table: "Onboarding",
                          comment: "VoiceOver hint: the button is disabled until a theme is chosen")
        }
        if RareRewardReleasePolicy.isEnabled,
           page == pageCount - 1,
           selectedRareRewardMode == nil {
            return String(localized: "レア粒の扱いを1つ選ぶと瓶をひらけます", table: "Onboarding",
                          comment: "VoiceOver hint: the button is disabled until a rare gem option is chosen")
        }
        switch page {
        case 0:
            return String(localized: "次は、記録を作らず一粒を試せるページです", table: "Onboarding",
                          comment: "VoiceOver hint for Next on page 1")
        case 1:
            return String(localized: "体験を省略して、最初のテーマを選べます", table: "Onboarding",
                          comment: "VoiceOver hint for Next on the trial page: skip the trial")
        case 2 where !RareRewardReleasePolicy.isEnabled:
            return String(localized: "ホームへ進みます。テーマと時間を確認してから集中を始められます", table: "Onboarding",
                          comment: "VoiceOver hint for the finishing button")
        default:
            return String(localized: "次のページへ進みます", table: "Onboarding",
                          comment: "VoiceOver hint for Next")
        }
    }

    /// The theme 「瓶をひらく」 creates: a valid name still in the field wins
    /// over a suggestion tapped earlier, so typing and tapping the button
    /// never silently drops what was typed.
    private func effectiveSelectedSubjects(within themeLimit: ThemeLimitSnapshot) -> Set<String> {
        OnboardingThemePolicy.effectiveSelection(
            selected: selectedSubjects,
            pending: pendingSubjectName
        ) { name in
            // One theme is chosen here, so replacing the selection never
            // needs more than one new slot.
            themeLimit.existingKeys.contains(SubjectNamePolicy.comparisonKey(name))
                || themeLimit.availableNewSubjectSlots > 0
        }
    }

    /// What the theme step needs to know about the themes already here.
    private struct ThemeLimitSnapshot {
        let existingNames: Set<String>
        let existingKeys: Set<String>
        let availableNewSubjectSlots: Int
    }

    /// Themes can exist before first-use setup is complete: presets an older
    /// version seeded, or, in iCloud mode, themes from the user's other
    /// devices. Only the ones finishing onboarding keeps take one of the
    /// twelve slots here (`countsAgainstThemeLimitBeforeSelection`); a local
    /// store reclaims an unselected preset without history, iCloud mode keeps
    /// everything that arrived.
    private var themeLimitSnapshot: ThemeLimitSnapshot {
        let subjects = existingSubjects
        let storesInCloud = persistenceMode == .cloudKit
        let builtInIDs = Set(SeedData.subjects.map(\.id))
        let occupiedCount = subjects.filter { subject in
            OnboardingThemePolicy.countsAgainstThemeLimitBeforeSelection(
                isBuiltInPreset: builtInIDs.contains(subject.id),
                storesInCloud: storesInCloud,
                hasHistory: !(subject.studySessions?.isEmpty ?? true)
                    || !(subject.achievementStones?.isEmpty ?? true)
            )
        }.count
        let names = Set(subjects.map(\.name))
        return ThemeLimitSnapshot(
            existingNames: names,
            existingKeys: Set(names.map(SubjectNamePolicy.comparisonKey)),
            availableNewSubjectSlots: max(0, Constants.App.maximumSubjects - occupiedCount)
        )
    }
}

private struct ValuePage: View {
    let persistenceMode: PersistenceLaunchMode
    let startedFreshOverRestore: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isCloudOfflineSession) private var isCloudOffline
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                // walk-edge-04. At accessibility sizes the promise comes
                // first and the decorative jar shrinks, so the first screen a
                // new user sees says what the app does instead of showing
                // only a jar and an English eyebrow.
                if dynamicTypeSize.isAccessibilitySize {
                    promise
                    OnboardingJar(pebbleCount: 7)
                        .frame(height: jarHeight)
                } else {
                    OnboardingJar(pebbleCount: 7)
                        .frame(height: jarHeight)
                    promise
                }

                VStack(spacing: 10) {
                    ValuePromise(
                        symbol: "archivebox.fill",
                        title: String(localized: "減らない", table: "Onboarding",
                                      comment: "Onboarding promise title: nothing you added shrinks (from 減らない。消えない。責めない。)"),
                        detail: String(localized: "積んだ粒と記録は、そのまま残る", table: "Onboarding",
                                       comment: "Onboarding promise detail: your gems and records stay")
                    )
                    ValuePromise(
                        symbol: "leaf.fill",
                        title: String(localized: "責めない", table: "Onboarding",
                                      comment: "Onboarding promise title: no guilt (from 減らない。消えない。責めない。)"),
                        detail: String(localized: "できない日があっても、警告や罰はない", table: "Onboarding",
                                       comment: "Onboarding promise detail: no warnings or penalties on days you can't focus")
                    )

                    // product-01 / launch-04. The storage choice was made
                    // seconds ago and confirmed with its full caveats; this
                    // page no longer repeats it a third time. Only an iCloud
                    // session can have a caption, and only when it says
                    // something this moment needs.
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

    private var promise: some View {
        VStack(spacing: 14) {
            // The English eyebrow is decoration; at AX sizes it would take
            // the first lines of the first screen.
            if !dynamicTypeSize.isAccessibilitySize {
                SectionEyebrow(text: "YOUR TIME, IN THE JAR")
            }
            Text("集中を終えると、一粒。", tableName: "Onboarding",
                 comment: "Onboarding page 1 headline: finish a focus, get a gem")
                .font(PomoGemTheme.brand(30))
                .multilineTextAlignment(.center)
                .foregroundStyle(PomoGemTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("onboarding.value-headline")
            Text("テーマと時間を選んで、集中をはじめる。\n完走すると、その時間が一粒になって瓶に残ります。",
                 tableName: "Onboarding",
                 comment: "Onboarding page 1: how a focus becomes a gem in the jar")
                .font(.body)
                .foregroundStyle(PomoGemTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Label {
                Text("25・45・60・90分のタイマーは無料", tableName: "Onboarding",
                     comment: "Onboarding page 1: the 25, 45, 60 and 90 minute timers are free")
            } icon: {
                Image(systemName: "timer")
            }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PomoGemTheme.amber)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding.free-timers")
        }
    }

    private var jarHeight: CGFloat {
        if dynamicTypeSize.isAccessibilitySize { return 120 }
        return verticalSizeClass == .compact ? 180 : 250
    }

    private var storageDetail: String? {
        guard persistenceMode == .cloudKit else { return nil }
        if isCloudOffline {
            return String(
                localized: "現在は端末に保存済みのデータを使っています。まだ届いていないiCloudのデータは、接続回復後に確認します。",
                table: "Onboarding",
                comment: "Onboarding page 1 while iCloud is offline: using data already on this device"
            )
        }
        // launch-06. An earlier jar now gets the restore screen instead of
        // this tutorial (see `CloudRestoreWaitingPolicy`), so the old 「この
        // 画面を開いたまま…お待ちください」 only reached new users, or told
        // someone who had just chosen not to wait to wait.
        guard startedFreshOverRestore else { return nil }
        return String(localized: "iCloudの記録は、届きしだいこのiPhoneにも表示されます。", table: "Onboarding",
                      comment: "Onboarding page 1 after choosing to start fresh over an iCloud restore")
    }
}

/// The one line that says which theme 「瓶をひらく」 will create. Pinned above
/// the button normally; inside the page at accessibility sizes.
private struct OnboardingSelectionSummary: View {
    let selection: Set<String>

    var body: some View {
        Text(summary)
        .font(.caption.weight(.semibold))
        .foregroundStyle(selection.isEmpty ? PomoGemTheme.muted : PomoGemTheme.amber)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("onboarding.selection-summary")
    }

    private var summary: String {
        guard let chosen = selection.sorted().first else {
            return String(localized: "テーマを1つ選ぶと、瓶をひらけます", table: "Onboarding",
                          comment: "Onboarding theme summary before a theme is chosen")
        }
        return String(localized: "最初のテーマ：\(SubjectSuggestionCatalog.displayName(forChosen: chosen))", table: "Onboarding",
                      comment: "Onboarding theme summary; %@ is the chosen theme's name")
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
                // Decorative English; at AX sizes it would take the page's
                // first lines (walk-edge-04).
                if !dynamicTypeSize.isAccessibilitySize {
                    SectionEyebrow(text: "THE FIRST DROP")
                }
                JarSpriteView(scene: scene, totalGrams: 0, pebbleCount: dropped ? 1 : 0)
                    .frame(width: 240, height: jarHeight)
                    .shadow(color: Color("subj.math").opacity(0.12), radius: 45)
                    .accessibilityLabel(jarAccessibilityLabel)
                    .accessibilityValue(jarAccessibilityValue)
                    .accessibilityHint(
                        dropped
                            ? Text("一粒目の着地が完了しました", tableName: "Onboarding",
                                   comment: "VoiceOver hint on the trial jar: the gem has landed")
                            : Text("下のボタンで、ためしの一粒を落とせます", tableName: "Onboarding",
                                   comment: "VoiceOver hint on the trial jar: the button below drops a trial gem")
                    )

                VStack(spacing: 12) {
                    if voiceOverEnabled, !dropped, !isDropping {
                        Text("ためしの一粒は任意です。記録を作らず、「次へ」でそのまま進めます。", tableName: "Onboarding",
                             comment: "Trial page with VoiceOver: the trial gem is optional; 次へ is the Next button")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(tryWithoutMotionTitle, action: completeWithoutAnimation)
                            .buttonStyle(PomoGemPrimaryButtonStyle())
                        Button(String(localized: "着地演出を試す", table: "Onboarding",
                                      comment: "Trial page button: try the landing animation"), action: startDrop)
                            .buttonStyle(PomoGemSecondaryButtonStyle())
                    } else if showsRecoveryActions, !dropped {
                        Text("着地を確認できませんでした。記録には影響しません。", tableName: "Onboarding",
                             comment: "Trial page: the landing could not be confirmed; records are not affected")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(String(localized: "もう一度", table: "Onboarding",
                                      comment: "Trial page button: try the drop again"), action: startDrop)
                            .buttonStyle(PomoGemSecondaryButtonStyle())
                        Button(tryWithoutMotionTitle, action: completeWithoutAnimation)
                            .buttonStyle(PomoGemPrimaryButtonStyle())
                    } else {
                        Button(action: startDrop) {
                            Label(dropButtonTitle, systemImage: dropButtonSymbol)
                        }
                        .buttonStyle(PomoGemSecondaryButtonStyle())
                        .disabled(dropped || isDropping)
                        .accessibilityValue(dropStateValue)
                    }

                    if dropped {
                        // walk-std-12. The proof moment names the promise:
                        // what this drop stands for in a real focus. 「本番
                        // では」 and 「この大きさ」 keep it from reading as
                        // "real gems look like this grey pebble" or as a
                        // contradiction of the 0g line below. The trial
                        // gem's colour and glow belong to the gem-brilliance
                        // branch (PebbleNode / GemArtwork), not this page.
                        Text("本番では、25分の集中でこの大きさの一粒（250g）が瓶に残ります。",
                             tableName: "Onboarding",
                             comment: "Onboarding trial drop: shown after the trial gem lands")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(PomoGemTheme.amber)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("onboarding.trial-meaning")
                            .transition(.opacity)
                    }

                    Text("任意の体験です。0g・記録には入りません。「次へ」で省略できます。", tableName: "Onboarding",
                         comment: "Trial page: optional, adds 0 g and no record; Next skips it")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: dropped)
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
                completeDrop(announcement: String(
                    localized: "一粒、着地しました。本番では、25分の集中でこの大きさの一粒（250グラム）が瓶に残ります。次へ進めます",
                    table: "Onboarding",
                    comment: "VoiceOver announcement when the onboarding trial gem lands"))
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
                argument: String(localized: "着地を確認できませんでした。もう一度試すか、演出を省略して進めます", table: "Onboarding",
                                 comment: "VoiceOver announcement: the trial landing could not be confirmed")
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
        // walk-std-12. Enter through the neck and fall the jar's full
        // height, the same path as Home's completion drop, instead of
        // appearing near the floor and landing before anyone notices. The
        // 2.5 s recovery below still covers the longer fall (under 1 s).
        scene.dropFromAbove(pebble)
    }

    private func completeWithoutAnimation() {
        guard !dropped else { return }
        let pebble = tutorialPebble()
        activeDropID = pebble.id
        scene.restore(pebbles: [pebble])
        completeDrop(announcement: String(
            localized: "演出を省略して一粒を積みました。本番では、25分の集中でこの大きさの一粒（250グラム）が瓶に残ります。次へ進めます",
            table: "Onboarding",
            comment: "VoiceOver announcement when the onboarding trial gem is placed without animation"))
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
            subjectName: String(localized: "ためし積み", table: "Onboarding",
                                comment: "Theme name of the onboarding trial gem (never saved)"),
            colorHex: Constants.Color.glassEdge,
            source: .timer,
            kind: .normal,
            grams: 0,
            isTutorial: true
        )
    }

    private var tryWithoutMotionTitle: String {
        String(localized: "動きを使わず一粒を試す", table: "Onboarding",
               comment: "Trial page button: add the trial gem without the animation")
    }

    private var dropStateValue: String {
        if isDropping {
            return String(localized: "落下中", table: "Onboarding", comment: "VoiceOver value: the trial gem is falling")
        }
        if dropped {
            return String(localized: "着地済み", table: "Onboarding", comment: "VoiceOver value: the trial gem has landed")
        }
        return String(localized: "落下前", table: "Onboarding", comment: "VoiceOver value: the trial gem has not been dropped yet")
    }

    private var dropButtonTitle: String {
        if dropped {
            return String(localized: "一粒、積もった", table: "Onboarding", comment: "Trial page button after the gem landed")
        }
        if isDropping {
            return String(localized: "一粒が落下中", table: "Onboarding", comment: "Trial page button while the gem falls")
        }
        return String(localized: "ためしに一粒、落としてみる", table: "Onboarding", comment: "Trial page button: drop a trial gem")
    }

    private var dropButtonSymbol: String {
        if dropped { return "checkmark" }
        if isDropping { return "hourglass" }
        return "arrow.down"
    }

    private var jarAccessibilityLabel: String {
        if dropped {
            return String(localized: "ためしの一粒が瓶に積もりました", table: "Onboarding",
                          comment: "VoiceOver label of the trial jar after the gem landed")
        }
        if isDropping {
            return String(localized: "ためしの一粒が瓶の中を落下しています", table: "Onboarding",
                          comment: "VoiceOver label of the trial jar while the gem falls")
        }
        return String(localized: "空の瓶", table: "Onboarding", comment: "VoiceOver label: the empty trial jar")
    }

    private var jarAccessibilityValue: String {
        if isDropping, !dropped {
            return String(localized: "落下中", table: "Onboarding", comment: "VoiceOver value: the trial gem is falling")
        }
        let gems = dropped ? 1 : 0
        return String(localized: "\(gems)粒、0グラム", table: "Onboarding",
                      comment: "VoiceOver value of the trial jar; %lld is its gem count (0 or 1), which always weighs 0 grams")
    }
}

private struct SubjectSetupPage: View {
    @Binding var selectedSubjects: Set<String>
    @Binding var customSubjectName: String
    @Binding var wantsNotifications: Bool
    /// What 「瓶をひらく」 will create. Chips and the chosen-theme rows show
    /// this, so a valid typed name visibly replaces an earlier chip.
    let effectiveSelection: Set<String>
    /// At accessibility sizes the pinned footer drops this summary, so the
    /// page shows it under its heading instead.
    let showsSelectionSummary: Bool
    let existingSubjectNames: Set<String>
    let availableNewSubjectSlots: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var customSubjectFeedback: String?
    @FocusState private var customSubjectFocused: Bool

    private var presetNames: Set<String> {
        Set(SubjectSuggestionCatalog.presets.map(\.name))
    }

    /// Committed custom names that are still what the button will use.
    private var customSubjects: [String] {
        selectedSubjects.intersection(effectiveSelection).subtracting(presetNames).sorted()
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
            return String(localized: "最大\(SubjectNamePolicy.maximumCharacters)文字", table: "Onboarding",
                          comment: "Theme name field: the character limit; %lld is 40")
        }
        return String(localized: "あと\(SubjectNamePolicy.remainingCharacters(for: customSubjectName))文字入力できます", table: "Onboarding",
                      comment: "Theme name field: %lld characters left")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        // A decorative English eyebrow in Japanese too; the
                        // English UI names the jar by its glossary noun.
                        SectionEyebrow(text: String(localized: "YOUR BOTTLE", table: "Onboarding",
                                                    comment: "Decorative uppercase eyebrow above 最初のテーマを選ぶ. en: YOUR JAR (glossary: jar, never bottle)"))
                    }
                    Text("最初のテーマを選ぶ", tableName: "Onboarding", comment: "Onboarding theme page heading: choose your first theme")
                        .font(PomoGemTheme.brand(30))
                    Text(SubjectSuggestionCatalog.setupDetail)
                        .font(.subheadline)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("このあとはホームで時間を選び、開始ボタンをタップ。テーマはいつでも変更できます。", tableName: "Onboarding",
                         comment: "Onboarding theme page: what happens next on Home")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsSelectionSummary {
                        OnboardingSelectionSummary(selection: effectiveSelection)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("候補から選ぶ", tableName: "Onboarding", comment: "Onboarding theme page section: pick from suggestions")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.muted)
                    Text("あとで設定から追加・編集できます。", tableName: "Onboarding",
                         comment: "Onboarding theme page: themes can be added and edited later in Settings")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // device-verify-2 P9: two columns only when every name fits
                // on one line in half the width, otherwise one full-width
                // column. The fixed two-column grid broke 「資料作成」 and
                // 「顧客対応」 in the middle of the word at the default size
                // on a 375 pt iPhone. (The same layout as PR #58 on main,
                // which English needs too: "Customer Support" and
                // "Development" never fit half of a 375 pt screen.)
                ThemeChoiceColumns(spacing: 10) {
                    ForEach(SubjectSuggestionCatalog.presets) { preset in
                        let isSelected = effectiveSelection.contains(preset.name)
                        Button {
                            choosePreset(preset)
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color(hex: preset.colorHex))
                                    .frame(width: 14, height: 14)
                                Text(preset.displayName)
                                    .font(.system(.body, design: .rounded, weight: .bold))
                                    // A name is never split across lines; the
                                    // one-column layout gives it the full
                                    // width, and only a name wider than that
                                    // shrinks a little.
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .layoutPriority(1)
                                Spacer(minLength: 4)
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? PomoGemTheme.amber : PomoGemTheme.muted)
                            }
                            .padding(.horizontal, 12)
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
                        .accessibilityValue(isSelected ? selectedValue : unselectedValue)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("自由に入力", tableName: "Onboarding", comment: "Onboarding theme page section: type your own theme")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.muted)
                    // launch-07: no quota line for a one-theme step. The
                    // message below still appears when no slot is left.
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
                        Button(String(localized: "選択", table: "Onboarding",
                                      comment: "Onboarding theme page: choose the typed theme name"), action: addCustomSubject)
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
                        Text("新しいテーマの枠がありません。既存のテーマを選ぶか、瓶をひらいた後に整理してください。", tableName: "Onboarding",
                             comment: "Onboarding theme page: the theme limit leaves no room for a new theme")
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
                            .accessibilityLabel(Text("\(name)を選択から外す", tableName: "Onboarding",
                                                     comment: "VoiceOver: remove the typed theme %@ from the selection"))
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
                        Text("毎日のリマインダー", tableName: "Onboarding", comment: "Onboarding toggle: Daily Reminder")
                            .font(.system(.body, design: .rounded, weight: .bold))
                        Text("\(reminderTimeText)に、集中を思い出す通知を受け取る", tableName: "Onboarding",
                             comment: "Onboarding reminder toggle detail; %@ is the reminder time, e.g. 20:00 / 8:00 PM")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(PomoGemTheme.amber)
                .padding(16)
                .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityIdentifier("onboarding.daily-reminder")

                Text("通知は任意です。時刻やオン・オフは設定で変更できます。タイマーの終了通知は、このリマインダーとは別に、最初に集中を始めるときに一度だけ許可をおたずねします。", tableName: "Onboarding",
                     comment: "Onboarding: notifications are optional; timer-end notifications are asked for once, at the first focus")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }
            .padding(.horizontal, 24)
            .padding(.top, dynamicTypeSize.isAccessibilitySize ? 16 : 36)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }

    private var selectedValue: String {
        String(localized: "選択中", table: "Onboarding", comment: "VoiceOver value: this option is selected")
    }

    private var unselectedValue: String {
        String(localized: "未選択", table: "Onboarding", comment: "VoiceOver value: this option is not selected")
    }

    /// Japanese keeps its 24-hour 「20:00」; other languages read the time the
    /// way the device writes it ("8:00 PM").
    private var reminderTimeText: String {
        let hour = Constants.Notification.defaultReminderHour
        let minute = Constants.Notification.defaultReminderMinute
        let locale = PomoGemLocale.current
        guard !PomoGemLocale.composesJapanese(locale),
              let time = Calendar.current.date(from: DateComponents(hour: hour, minute: minute))
        else {
            return String(format: "%02d:%02d", hour, minute)
        }
        return time.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
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
            showCustomSubjectFeedback(String(localized: "同じ名前の候補「\(preset.displayName)」を選択しました。", table: "Onboarding",
                                             comment: "Onboarding: the typed name matches suggestion %@, which is now selected"))
            return
        }

        if let existing = customSubjects.first(where: {
            SubjectNamePolicy.comparisonKey($0) == normalized
        }) {
            customSubjectName = ""
            customSubjectFocused = false
            showCustomSubjectFeedback(String(localized: "「\(existing)」を選択しています。", table: "Onboarding",
                                             comment: "Onboarding: the typed theme %@ is already selected"))
            return
        }

        guard canChooseSubject(named: name) else {
            showCustomSubjectFeedback(String(localized: "テーマは合計最大\(Constants.App.maximumSubjects)件です。不要なテーマは設定から削除できます。", table: "Onboarding",
                                             comment: "Onboarding: theme limit reached; %lld is the maximum number of themes (12)"))
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
            showCustomSubjectFeedback(String(localized: "追加できるテーマは合計最大\(Constants.App.maximumSubjects)件です。", table: "Onboarding",
                                             comment: "Onboarding: theme limit reached; %lld is the maximum number of themes (12)"))
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

/// Equal columns for the onboarding theme choices: two when the widest
/// choice fits on one line in half the width, otherwise one (device-verify-2
/// P9). Each choice is measured at its ideal (one-line) width, so the
/// decision follows the text size and the screen instead of a fixed rule.
private struct ThemeChoiceColumns: Layout {
    var spacing: CGFloat

    private struct Arrangement {
        var size: CGSize
        var frames: [CGRect]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func arrange(width proposedWidth: CGFloat?, subviews: Subviews) -> Arrangement {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let width = proposedWidth ?? (widest * 2 + spacing)
        let columns = widest * 2 + spacing <= width ? 2 : 1
        let columnWidth = columns == 2 ? (width - spacing) / 2 : width
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for rowStart in stride(from: 0, to: subviews.count, by: columns) {
            let row = rowStart..<min(rowStart + columns, subviews.count)
            let height = row.map {
                subviews[$0].sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            }.max() ?? 0
            for (column, _) in row.enumerated() {
                frames.append(CGRect(
                    x: CGFloat(column) * (columnWidth + spacing),
                    y: y,
                    width: columnWidth,
                    height: height
                ))
            }
            y += height + spacing
        }
        return Arrangement(
            size: CGSize(width: width, height: max(0, y - spacing)),
            frames: frames
        )
    }
}

private struct RareRewardOnboardingPage: View {
    @Binding var selection: RareRewardMode?

    var body: some View {
        ScrollView {
            RareRewardChoicePanel(
                selection: $selection,
                eyebrow: "OPTIONAL VARIATION",
                title: String(localized: "レア粒は、自分で選ぶ。", table: "Onboarding",
                              comment: "Rare gem choice heading: you decide about rare gems"),
                introduction: String(
                    localized: "どれを選んでも、質量・粒の融合・結晶・成果・使える機能は同じです。ランダムな結果を使わない「抽選しない」が安全な基準です。",
                    table: "Onboarding",
                    comment: "Rare gem choice: every option keeps mass, fusion, crystals, achievements and features the same; 抽選しない is the no-draw option"
                )
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
                    .accessibilityValue(selection == mode
                        ? Text("選択中", tableName: "Onboarding", comment: "VoiceOver value: this option is selected")
                        : Text("未選択", tableName: "Onboarding", comment: "VoiceOver value: this option is not selected"))
                    .accessibilityHint(choiceDetail(for: mode))
                    .accessibilityAddTraits(selection == mode ? .isSelected : [])
                    .accessibilityIdentifier("rare-reward.choice.\(mode.rawValue)")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                disclosureRow(
                    symbol: "equal.circle.fill",
                    text: String(localized: "全モードで、1回の完走が積む質量と、粒の融合・結晶の進み方は同じ", table: "Onboarding",
                                 comment: "Rare gem disclosure: every mode adds the same mass and fuses gems into crystals the same way")
                )
                disclosureRow(
                    symbol: "percent",
                    text: String(
                        localized: "抽選する場合の自然確率：いつもの粒 \(GachaEngine.probabilityLabel(for: .normal))、金 \(GachaEngine.probabilityLabel(for: .gold))、虹 \(GachaEngine.probabilityLabel(for: .prism))",
                        table: "Onboarding",
                        comment: "Rare gem disclosure: natural odds; %1$@ usual gem, %2$@ gold, %3$@ rainbow (percentages)"
                    )
                )
                disclosureRow(
                    symbol: "checkmark.shield.fill",
                    text: String(
                        localized: "実測タイマーで250g積むごとに1抽選。端数は次回へ繰り越します。\(GachaEngine.goldGuaranteeDisclosure)",
                        table: "Onboarding",
                        comment: "Rare gem disclosure: one draw per 250 g of timed focus, the remainder carries over; %@ is the gold guarantee sentence"
                    )
                )
                disclosureRow(
                    symbol: "gearshape.fill",
                    text: String(
                        localized: "あとから設定で変更できます。抽選しない間は乱数を使わず、その間の質量も抽選用には貯めません。既存の端数と保証カウントは停止します",
                        table: "Onboarding",
                        comment: "Rare gem disclosure: changeable later in Settings; with no draws, nothing random is used"
                    )
                )
            }
            .padding(15)
            .background(PomoGemTheme.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func choiceDetail(for mode: RareRewardMode) -> String {
        switch mode {
        case .off:
            String(localized: "通常の粒だけを積みます。抽選せず、抽選用の端数と金の保証カウントも動かしません。", table: "Onboarding",
                   comment: "Rare gem choice detail: no draws")
        case .quiet:
            String(localized: "金・虹の種類は履歴に残しますが、追加の発光・専用音・専用触覚は使いません。", table: "Onboarding",
                   comment: "Rare gem choice detail: quiet")
        case .standard:
            String(localized: "確率と質量は控えめと同じ。金・虹に追加の発光・専用音・専用触覚を使います。", table: "Onboarding",
                   comment: "Rare gem choice detail: standard (控えめ is the quiet option)")
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
