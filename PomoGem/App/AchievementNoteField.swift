import SwiftUI

/// The 記念石 name field shared by 「成果を積む」 and the Log editor. It never
/// rewrites what is being typed; see `AchievementNotePolicy`. The counter
/// sits beside the title rather than under the field, so it stays visible
/// above the keyboard on small phones.
struct AchievementNoteField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let accessibilityIdentifier: String

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
                .accessibilityLabel(title)
                .accessibilityHint(AchievementNotePolicy.statusMessage(for: text))
                .accessibilityIdentifier(accessibilityIdentifier)
            if isTooLong {
                Text(AchievementNotePolicy.statusMessage(for: text))
                    .font(.caption)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
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
