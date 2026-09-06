import Foundation

/// One source of truth for study subjects and work-theme names.
///
/// New writes are validated before `sanitized(_:)` is persisted. Existing
/// CloudKit values are never rewritten in bulk; `displayName(_:fallback:)`
/// gives UI and system surfaces a bounded value when older data is longer.
enum SubjectNamePolicy {
    static let maximumCharacters = 40

    enum ValidationError: Error, Equatable, Sendable {
        case empty
        case tooLong(excessCharacters: Int)

        var message: String {
            switch self {
            case .empty:
                "テーマ名を入力してください。"
            case let .tooLong(excessCharacters):
                "テーマ名は\(maximumCharacters)文字以内で入力してください（\(excessCharacters)文字超過）。"
            }
        }
    }

    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Defensive persistence/display sanitizer. Interactive flows should call
    /// `validationError(for:)` first so truncation is never surprising.
    static func sanitized(_ value: String) -> String {
        String(trimmed(value).prefix(maximumCharacters))
    }

    static func validationError(for value: String) -> ValidationError? {
        let value = trimmed(value)
        guard !value.isEmpty else { return .empty }
        let excess = value.count - maximumCharacters
        guard excess <= 0 else { return .tooLong(excessCharacters: excess) }
        return nil
    }

    static func validated(_ value: String) -> String? {
        guard validationError(for: value) == nil else { return nil }
        return sanitized(value)
    }

    /// A stable duplicate key shared by onboarding, Settings, and Root save.
    /// Compatibility composition plus folding handles case, accents, and
    /// full-width/half-width variants consistently across devices.
    static func comparisonKey(_ value: String) -> String {
        sanitized(value)
            .precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    static func displayName(
        _ value: String,
        fallback: String = "テーマ"
    ) -> String {
        let value = sanitized(value)
        return value.isEmpty ? sanitized(fallback) : value
    }

    static func characterCount(for value: String) -> Int {
        trimmed(value).count
    }

    static func remainingCharacters(for value: String) -> Int {
        max(0, maximumCharacters - characterCount(for: value))
    }
}

extension Subject {
    var safeDisplayName: String {
        SubjectNamePolicy.displayName(name)
    }
}
