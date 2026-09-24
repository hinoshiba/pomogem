import SwiftUI

struct AchievementDraft {
    let kind: AchievementKind
    let note: String
    let achievedAt: Date
}

/// 「成果を積む」: turns a milestone into a 0 g 記念石. The details step keeps
/// 「この成果を積む」 pinned above the home indicator (and above the keyboard
/// while the name is being typed), so the save is never below the fold. When
/// the button is disabled because the name is too long, the reason sits in
/// the same pinned bar.
struct AchievementEntrySheet: View {
    private static let noteFieldScrollID = "achievement.create.note-field"
    private static let topScrollID = "achievement.create.top"

    let subjects: [Subject]
    /// Returns nil once saved, otherwise the reason, shown beside the button.
    let onAdd: (Subject, AchievementDraft) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: AchievementKind?
    @State private var selectedSubjectID: UUID?
    @State private var note = ""
    @State private var achievedAt = Date.now
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var noteIsFocused = false

    init(
        initialSubject: Subject?,
        subjects: [Subject],
        onAdd: @escaping (Subject, AchievementDraft) -> String?
    ) {
        self.subjects = subjects
        self.onAdd = onAdd
        _selectedSubjectID = State(
            initialValue: ThemeSelectionMenu.initialID(for: initialSubject, in: subjects)
        )
    }

    private var selectedSubject: Subject? {
        subjects.first { $0.id == selectedSubjectID }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let selectedKind {
                        detailsStep(kind: selectedKind)
                    } else {
                        kindStep
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .id(Self.topScrollID)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let selectedKind {
                    saveBar(kind: selectedKind)
                }
            }
            // On a small phone the keyboard leaves only a sliver above the
            // pinned bar, and the system's own scroll counts a field that is
            // half under the bar as visible. Bring the whole field above the
            // bar once the keyboard is up, and again when the bar grows to
            // explain an over-long name.
            // Both steps share this scroll view. At large text a kind picked
            // from low in the list otherwise opened the details already
            // scrolled past the theme and the name, at 「達成した日」.
            .onChange(of: selectedKind) { _, _ in
                scrollProxy.scrollTo(Self.topScrollID, anchor: .top)
            }
            .onChange(of: noteIsFocused) { _, focused in
                guard focused else { return }
                revealNoteField(scrollProxy, after: .milliseconds(350))
            }
            .onChange(of: AchievementNotePolicy.isTooLong(note)) { _, _ in
                guard noteIsFocused else { return }
                revealNoteField(scrollProxy, after: .milliseconds(50))
            }
            }
            .background(NightBackground())
            .navigationTitle(selectedKind == nil ? "成果を選ぶ" : "記念石にする")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if selectedKind != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("戻る") { selectedKind = nil }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton(
                        accessibilityIdentifier: "achievement.create.close"
                    ) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var kindStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                SectionEyebrow(text: "MILESTONE")
                Text("どんな成果だった？")
                    .font(PomoGemTheme.brand(26))
                Text(achievementIntroduction)
                    .font(.subheadline)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(AchievementKind.allCases) { kind in
                Button {
                    selectedKind = kind
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: kind.systemImage)
                            .font(.title2)
                            .foregroundStyle(PomoGemTheme.amber)
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.title)
                                .font(.system(.headline, design: .rounded, weight: .bold))
                            Text(kind.detail)
                                .font(.caption)
                                .foregroundStyle(PomoGemTheme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(PomoGemTheme.muted)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                    .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(PomoGemBareButtonStyle())
            }
        }
    }

    private var achievementIntroduction: String {
        "満点・試験合格・納品・公開などの節目を、集中時間とは別のひとまわり大きな記念石として残せます。"
    }

    private func detailsStep(kind: AchievementKind) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: kind.systemImage)
                    .font(.title)
                    .foregroundStyle(PomoGemTheme.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(PomoGemTheme.brand(24))
                    Text(selectedSubject?.safeDisplayName ?? "テーマを選んでください")
                        .font(.subheadline)
                        .foregroundStyle(PomoGemTheme.muted)
                }
            }

            ThemeSelectionMenu(
                subjects: subjects,
                selectedID: $selectedSubjectID,
                accessibilityHint: "成果を結びつけるテーマを変更できます",
                accessibilityIdentifier: "achievement.create.subject-picker"
            )

            AchievementNoteField(
                title: "成果名（任意）",
                placeholder: kind.notePlaceholder,
                text: $note,
                accessibilityIdentifier: "achievement.create.note",
                onFocusChange: { noteIsFocused = $0 }
            )
            .id(Self.noteFieldScrollID)

            DatePicker(
                "達成した日",
                selection: $achievedAt,
                in: ...Date.now,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)

            Label(
                "記念石は0gで、集中時間・質量・通常の粒数には加わりません。瓶では新しい12個が動き、前の石も記録棚にずっと残ります。",
                systemImage: "checkmark.shield"
            )
            .font(.caption)
            .foregroundStyle(PomoGemTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func revealNoteField(_ scrollProxy: ScrollViewProxy, after delay: Duration) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard noteIsFocused else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                // nil: the least scroll that shows the whole field, so
                // nothing moves on a phone where it is already clear.
                scrollProxy.scrollTo(Self.noteFieldScrollID, anchor: nil)
            }
        }
    }

    private func saveBar(kind: AchievementKind) -> some View {
        VStack(spacing: 8) {
            AchievementNoteLimitMessage(text: note)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("achievement.create.error")
            }
            Button {
                guard !isSubmitting else { return }
                guard let selectedSubject else { return }
                isSubmitting = true
                errorMessage = onAdd(
                    selectedSubject,
                    AchievementDraft(kind: kind, note: note, achievedAt: achievedAt)
                )
                if errorMessage == nil {
                    dismiss()
                } else {
                    isSubmitting = false
                    if let errorMessage, UIAccessibility.isVoiceOverRunning {
                        UIAccessibility.post(notification: .announcement, argument: errorMessage)
                    }
                }
            } label: {
                if isSubmitting {
                    ProgressView().tint(PomoGemTheme.background)
                } else {
                    Label("この成果を積む", systemImage: "medal.fill")
                }
            }
            .buttonStyle(PomoGemPrimaryButtonStyle())
            .disabled(selectedSubject == nil || isSubmitting || AchievementNotePolicy.isTooLong(note))
            .accessibilityIdentifier("achievement.create.save")
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider().overlay(PomoGemTheme.glassEdge.opacity(0.16))
        }
    }
}
