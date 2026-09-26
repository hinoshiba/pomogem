import SwiftUI

/// The 記念石 name field shared by 「成果を積む」 and the Log editor. It never
/// rewrites what is being typed; see `AchievementNotePolicy`. The counter
/// sits beside the title rather than under the field, so it stays visible
/// above the keyboard on small phones. The full over-limit sentence is not
/// under the field: both screens show it next to the save button it
/// disables (`AchievementNoteLimitMessage`), which on a small phone with the
/// keyboard up is the part of the screen that is still visible.
struct AchievementNoteField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let accessibilityIdentifier: String
    var onFocusChange: (Bool) -> Void = { _ in }

    @FocusState private var isFocused: Bool

    private var isTooLong: Bool { AchievementNotePolicy.isTooLong(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    titleText
                    Spacer(minLength: 8)
                    counterText
                }
                VStack(alignment: .leading, spacing: 2) {
                    titleText
                    counterText
                }
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .padding(14)
                .background(PomoGemTheme.raised, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    if isTooLong {
                        RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.8), lineWidth: 1)
                    }
                }
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in onFocusChange(focused) }
                .accessibilityLabel(title)
                .accessibilityHint(AchievementNotePolicy.statusMessage(for: text))
                .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(PomoGemTheme.muted)
            // The field itself carries this as its label.
            .accessibilityHidden(true)
    }

    private var counterText: some View {
        Text(AchievementNotePolicy.shortStatus(for: text))
            .font(.caption.weight(isTooLong ? .bold : .regular))
            .monospacedDigit()
            .foregroundStyle(isTooLong ? Color.red : PomoGemTheme.muted)
            .accessibilityIdentifier("achievement.note.counter")
    }
}

/// Why a save button is disabled when the 記念石 name is over the limit,
/// shown directly above that button.
struct AchievementNoteLimitMessage: View {
    let text: String

    var body: some View {
        if AchievementNotePolicy.isTooLong(text) {
            Label(
                AchievementNotePolicy.statusMessage(for: text),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(Color.red.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("achievement.note.limit-message")
        }
    }
}
