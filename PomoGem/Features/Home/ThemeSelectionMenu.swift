import SwiftUI

/// The テーマ menu shared by the two ways to add to the jar from Home's menu,
/// 「時間を手動で積む」 and 「成果を積む」. The choice belongs to the sheet: it
/// never writes Home's selected theme, so back-filling time for another theme
/// does not also change what the next timer starts with.
struct ThemeSelectionMenu: View {
    let subjects: [Subject]
    @Binding var selectedID: UUID?
    let accessibilityHint: String
    let accessibilityIdentifier: String

    private var selectedSubject: Subject? {
        subjects.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("テーマ")
                .font(.caption.weight(.bold))
                .foregroundStyle(PomoGemTheme.muted)
                .accessibilityHidden(true)
            Menu {
                ForEach(subjects) { subject in
                    Button {
                        selectedID = subject.id
                    } label: {
                        if selectedID == subject.id {
                            Label(subject.safeDisplayName, systemImage: "checkmark")
                        } else {
                            Text(subject.safeDisplayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Color(hex: selectedSubject?.colorHex ?? Constants.Color.textMute))
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text(selectedSubject?.safeDisplayName ?? "選択してください")
                        .font(.system(.body, design: .rounded, weight: .bold))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(PomoGemTheme.muted)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(PomoGemTheme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(subjects.isEmpty)
            .accessibilityLabel("テーマ、\(selectedSubject?.safeDisplayName ?? "未選択")")
            .accessibilityHint(accessibilityHint)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }
}

extension ThemeSelectionMenu {
    /// The sheet's starting theme: Home's selection while it is still active,
    /// otherwise the first active theme.
    static func initialID(for initialSubject: Subject?, in subjects: [Subject]) -> UUID? {
        initialSubject.flatMap { initial in
            subjects.contains(where: { $0.id == initial.id }) ? initial.id : nil
        } ?? subjects.first?.id
    }
}
