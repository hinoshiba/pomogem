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
                String(localized: "テーマ名を入力してください。", table: "Onboarding",
                       comment: "Theme name validation: the name is empty")
            case let .tooLong(excessCharacters):
                String(
                    localized: "テーマ名は\(maximumCharacters)文字以内で入力してください（\(excessCharacters)文字超過）。",
                    table: "Onboarding",
                    comment: "Theme name validation: %1$lld is the character limit (always 40), %2$lld how many characters too many"
                )
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

    /// A bounded stored name. Its result is also written into snapshots and
    /// aggregates, so the default fallback is the Japanese data value; screens
    /// show `localizedDisplayName(_:subjectID:)` instead.
    static func displayName(
        _ value: String,
        fallback: String = "テーマ" // l10n-ignore: stored fallback name (snapshots), mapped by localizedDisplayName
    ) -> String {
        let value = sanitized(value)
        return value.isEmpty ? sanitized(fallback) : value
    }

    /// The name to show for a stored theme name, in the app's language.
    /// Display only: never persist, sync, export or compare the result
    /// (L10N D6). Names the app itself stored in Japanese are mapped:
    /// - an untouched built-in preset (英語 … 社会): when `subjectID` is
    ///   given, only for that preset's fixed ID with its canonical name, so a
    ///   renamed built-in keeps the user's name. Snapshots and aggregates that
    ///   carry no ID (nil) are mapped by the canonical name alone.
    /// - the legacy aggregate names 「過去の集中」 and 「過去の集中 N」.
    /// - 「アーカイブ済みのテーマ」 and 「テーマ」, the fallbacks written when a
    ///   theme had no name.
    /// Everything else is the user's own name and is returned unchanged
    /// (bounded like `displayName(_:fallback:)`).
    static func localizedDisplayName(
        _ storedName: String,
        subjectID: UUID? = nil,
        bundle: Bundle = .main
    ) -> String {
        let name = sanitized(storedName)
        if name.isEmpty {
            return LegacyStoredName.untitledTheme.localized(bundle: bundle)
        }
        let preset: SeedData.Preset?
        if let subjectID {
            preset = SeedData.subjects.first { $0.id == subjectID }
        } else {
            preset = SeedData.subjects.first { $0.name == name }
        }
        if let preset, preset.name == name {
            return preset.displayName(bundle: bundle)
        }
        return LegacyStoredName(name)?.localized(bundle: bundle) ?? name
    }

    /// Japanese names the app itself has written into snapshots and
    /// aggregates, recognised only for display.
    private enum LegacyStoredName {
        case earlierFocus(ordinal: Int)
        case archivedTheme
        case untitledTheme

        // l10n-ignore-begin: the stored Japanese values this maps from
        init?(_ name: String) {
            switch name {
            case AggregateSubjectFraction.legacySubjectName(at: 0):
                self = .earlierFocus(ordinal: 1)
            case "アーカイブ済みのテーマ":
                self = .archivedTheme
            case "テーマ":
                self = .untitledTheme
            default:
                let prefix = AggregateSubjectFraction.legacySubjectName(at: 0) + " "
                guard name.hasPrefix(prefix),
                      let ordinal = Int(name.dropFirst(prefix.count)),
                      ordinal > 1,
                      AggregateSubjectFraction.legacySubjectName(at: ordinal - 1) == name
                else { return nil }
                self = .earlierFocus(ordinal: ordinal)
            }
        }
        // l10n-ignore-end

        func localized(bundle: Bundle) -> String {
            switch self {
            case .earlierFocus(ordinal: 1):
                String(localized: "過去の集中", table: "Onboarding", bundle: bundle,
                       comment: "Name for focus from an old jar layer whose themes are unknown")
            case let .earlierFocus(ordinal):
                String(localized: "過去の集中 \(ordinal)", table: "Onboarding", bundle: bundle,
                       comment: "Name for one colour of an old jar layer whose themes are unknown; %lld is its number (2, 3, …)")
            case .archivedTheme:
                String(localized: "アーカイブ済みのテーマ", table: "Onboarding", bundle: bundle,
                       comment: "Name shown for a record whose theme was deleted and left no name")
            case .untitledTheme:
                // 「テーマ」 is also the Onboarding restore screen's count label
                // ("Themes"), so this one needs its own key.
                String(localized: "subject.untitled-name", defaultValue: "テーマ", table: "Onboarding", bundle: bundle,
                       comment: "Name shown for a theme that has no name")
            }
        }
    }

    static func characterCount(for value: String) -> Int {
        trimmed(value).count
    }

    static func remainingCharacters(for value: String) -> Int {
        max(0, maximumCharacters - characterCount(for: value))
    }
}

extension Subject {
    /// The stored name, bounded. Also used for snapshots and comparisons, so
    /// it is never localized; screens use `localizedDisplayName`.
    var safeDisplayName: String {
        SubjectNamePolicy.displayName(name)
    }

    /// Display only: an untouched built-in preset reads in the app's
    /// language (「英語」 is "English"); every other theme reads as named.
    var localizedDisplayName: String {
        SubjectNamePolicy.localizedDisplayName(name, subjectID: id)
    }
}
