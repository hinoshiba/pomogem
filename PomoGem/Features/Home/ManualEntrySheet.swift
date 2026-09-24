import SwiftUI

/// 「時間を手動で積む」: a self-reported block of focus, saved only after an
/// explicit confirmation and counted against the per-device daily allowance.
///
/// The sheet owns its theme choice (Home's selection is only the starting
/// point) and keeps 「確認して積む」 pinned above the home indicator once a
/// duration is chosen, so the commit button is reachable without scrolling at
/// every text size and on the smallest phones.
struct ManualEntrySheet: View {
    let subjects: [Subject]
    let counterState: ManualCounterState
    /// Returns nil once saved (Home then closes the sheet), otherwise the
    /// reason, shown beside the button.
    let onAdd: (Subject, ManualDuration) -> String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.pomogemReduceMotionOverride) private var reduceMotionOverride
    @State private var selectedSubjectID: UUID?
    @State private var selectedDuration: ManualDuration?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @AccessibilityFocusState private var confirmationHeadingIsFocused: Bool

    private static let confirmationCardID = "manual.confirmation-card"

    init(
        initialSubject: Subject?,
        subjects: [Subject],
        counterState: ManualCounterState,
        onAdd: @escaping (Subject, ManualDuration) -> String?
    ) {
        self.subjects = subjects
        self.counterState = counterState
        self.onAdd = onAdd
        _selectedSubjectID = State(
            initialValue: ThemeSelectionMenu.initialID(for: initialSubject, in: subjects)
        )
    }

    private var reduceMotion: Bool {
        reduceMotionOverride ?? systemReduceMotion
    }

    private var selectedSubject: Subject? {
        subjects.first { $0.id == selectedSubjectID }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(at: context.date)
        }
    }

    private func content(at date: Date) -> some View {
        let availability = FairnessPolicy.manualEntryAvailability(
            state: counterState,
            at: date
        )

        return NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        ThemeSelectionMenu(
                            subjects: subjects,
                            selectedID: $selectedSubjectID,
                            accessibilityHint: "積むテーマを変更できます。ホームで選んでいるテーマは変わりません",
                            accessibilityIdentifier: "manual.subject-picker"
                        )
                        remainingCount(availability)
                        durationButtons(isEnabled: availability.isAllowed && selectedSubject != nil)
                        if let selectedDuration, availability.isAllowed {
                            confirmationCard(
                                duration: selectedDuration,
                                availability: availability
                            )
                            .id(Self.confirmationCardID)
                        }
                        fairnessCopy
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: selectedDuration) { _, duration in
                    errorMessage = nil
                    guard duration != nil else { return }
                    revealConfirmation(using: proxy)
                }
                .onChange(of: selectedSubjectID) { _, _ in
                    errorMessage = nil
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let selectedDuration, availability.isAllowed {
                    confirmBar(duration: selectedDuration, availability: availability)
                }
            }
            .background(NightBackground())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton { dismiss() }
                }
            }
        }
        .onChange(of: availability.isAllowed) { _, isAllowed in
            if !isAllowed {
                selectedDuration = nil
                isSubmitting = false
            }
        }
    }

    /// Choosing a duration only previews it. Bring the summary into view and
    /// move VoiceOver there so the second step is never silently off-screen.
    private func revealConfirmation(using proxy: ScrollViewProxy) {
        Task { @MainActor in
            // Let the card join the layout before scrolling to it.
            await Task.yield()
            withAnimation(reduceMotion ? nil : .snappy) {
                proxy.scrollTo(Self.confirmationCardID, anchor: .bottom)
            }
            confirmationHeadingIsFocused = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionEyebrow(text: "SELF-REPORTED")
            Text("手動で積む")
                .font(PomoGemTheme.brand(26))
                .accessibilityAddTraits(.isHeader)
            Text("タイマーを使わずに集中した時間を、あとから瓶に積めます。")
                .font(.subheadline)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func remainingCount(_ availability: ManualEntryAvailability) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: availability.isAllowed ? "checkmark.circle.fill" : "clock.badge.xmark")
                .font(.title3)
                .foregroundStyle(availability.isAllowed ? PomoGemTheme.amber : PomoGemTheme.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("この端末で本日あと\(availability.remainingEntries)回")
                    .font(.headline)
                    .accessibilityIdentifier("manual.remaining-count")
                Text(
                    availability.isAllowed
                        ? "時間を選ぶと、下に内容の確認が出ます。「確認して積む」を押すまで保存されません。"
                        : "この端末での本日の上限です。朝4:00に3回へ切り替わります。"
                )
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 13))
    }

    private var fairnessCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(Constants.UIStrings.fairnessNote, systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("この端末で1日3回まで・朝4:00に回数が切り替わります")
                .font(.caption2)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func confirmationCard(
        duration: ManualDuration,
        availability: ManualEntryAvailability
    ) -> some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionEyebrow(text: "CONFIRM")
                    Text("この内容で積みますか？")
                        .font(PomoGemTheme.brand(21))
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($confirmationHeadingIsFocused)
                }

                VStack(spacing: 10) {
                    confirmationRow(title: "テーマ", value: selectedSubject?.safeDisplayName ?? "未選択")
                    confirmationRow(title: "時間", value: durationTitle(duration))
                    confirmationRow(title: "加算", value: "+\(duration.grams)g")
                    confirmationRow(
                        title: "保存後",
                        value: "この端末で本日あと\(availability.remainingEntriesAfterSaving)回"
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func confirmBar(
        duration: ManualDuration,
        availability: ManualEntryAvailability
    ) -> some View {
        VStack(spacing: 8) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("manual.error")
            }
            Button {
                guard !isSubmitting, let selectedSubject else { return }
                isSubmitting = true
                errorMessage = onAdd(selectedSubject, duration)
                if errorMessage != nil {
                    isSubmitting = false
                    announce(errorMessage)
                }
            } label: {
                if isSubmitting {
                    ProgressView().tint(PomoGemTheme.background)
                } else {
                    Label("確認して積む", systemImage: "plus.circle.fill")
                }
            }
            .buttonStyle(PomoGemPrimaryButtonStyle())
            .disabled(selectedSubject == nil || !availability.isAllowed || isSubmitting)
            .accessibilityHint(
                "\(selectedSubject?.safeDisplayName ?? "テーマ")に\(durationTitle(duration))、\(duration.grams)グラムを積みます"
            )
            .accessibilityIdentifier("manual.confirm")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().overlay(PomoGemTheme.glassEdge.opacity(0.16))
        }
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }

    private func announce(_ message: String?) {
        guard let message, UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func confirmationRow(title: String, value: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Side by side, a long value wraps a few characters per line.
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.muted)
                    Text(value)
                        .font(.subheadline.weight(.bold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PomoGemTheme.muted)
                    Spacer(minLength: 12)
                    Text(value)
                        .font(.subheadline.weight(.bold))
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func durationTitle(_ duration: ManualDuration) -> String {
        switch duration {
        case .thirtyMinutes: "30分"
        case .sixtyMinutes: "1時間"
        case .oneHundredTwentyMinutes: "2時間"
        }
    }

    @ViewBuilder
    private func durationButtons(isEnabled: Bool) -> some View {
        if dynamicTypeSize.isAccessibilitySize || verticalSizeClass == .compact {
            VStack(spacing: 10) {
                manualButtons(isEnabled: isEnabled)
            }
        } else {
            HStack(spacing: 10) {
                manualButtons(isEnabled: isEnabled)
            }
        }
    }

    @ViewBuilder
    private func manualButtons(isEnabled: Bool) -> some View {
        ForEach(ManualDuration.allCases, id: \.self) { duration in
            ManualButton(
                title: durationTitle(duration),
                grams: duration.grams,
                selected: selectedDuration == duration,
                isEnabled: isEnabled
            ) { selectedDuration = duration }
        }
    }
}

private struct ManualButton: View {
    let title: String
    let grams: Int
    let selected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title).font(.system(.headline, design: .rounded, weight: .bold))
                Text("+\(grams)g")
                    .font(.caption)
                    .foregroundStyle(
                        selected
                            ? PomoGemTheme.background.opacity(0.72)
                            : PomoGemTheme.muted
                    )
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 78)
            .foregroundStyle(selected ? PomoGemTheme.background : PomoGemTheme.text)
            .background(
                selected ? PomoGemTheme.amber : PomoGemTheme.raised,
                in: RoundedRectangle(cornerRadius: 13)
            )
        }
        .buttonStyle(PomoGemBareButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel("\(title)、\(grams)グラム加算")
        .accessibilityHint(isEnabled ? "内容の確認へ進みます" : "本日の手動追加上限です")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
