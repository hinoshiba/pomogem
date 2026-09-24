import Foundation

/// The optional name of a 記念石, such as 「TOEIC 800点」 or 「英検 準1級」.
///
/// The text field keeps exactly what the user types — spaces, full-width
/// spaces and an in-progress Japanese composition included — and the bound is
/// enforced when the stone is saved (`AchievementStone.sanitizedNote`), with
/// a live count before that, the same way theme names work. Rewriting the
/// binding on every keystroke deleted each space the moment it was typed and
/// could cut a marked-text composition in half near the limit.
enum AchievementNotePolicy {
    static let maximumCharacters = 40

    static func characterCount(for value: String) -> Int {
        value.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    static func excessCharacters(for value: String) -> Int {
        max(0, characterCount(for: value) - maximumCharacters)
    }

    static func isTooLong(_ value: String) -> Bool {
        excessCharacters(for: value) > 0
    }

    /// The compact counter beside the field's title, where it stays in view
    /// above the keyboard while typing.
    static func shortStatus(for value: String) -> String {
        let excess = excessCharacters(for: value)
        if excess > 0 { return "\(excess)文字超過" }
        return "あと\(maximumCharacters - characterCount(for: value))文字"
    }

    static func statusMessage(for value: String) -> String {
        let excess = excessCharacters(for: value)
        if excess > 0 {
            return "\(maximumCharacters)文字以内で入力してください（\(excess)文字超過）。"
        }
        return "あと\(maximumCharacters - characterCount(for: value))文字入力できます。"
    }
}
