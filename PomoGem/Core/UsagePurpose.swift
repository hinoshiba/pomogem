import Foundation

enum UsagePurpose: String, CaseIterable, Identifiable, Sendable {
    case study
    case work

    struct CategoryPreset: Identifiable, Hashable, Sendable {
        /// The name a theme chosen from this suggestion is saved with. A
        /// built-in study preset keeps its canonical Japanese name, the one
        /// its fixed-ID row carries on every device; a work suggestion is
        /// saved as the user saw it, in the app's language (L10N D6).
        let name: String
        /// What the suggestion shows. Display only: never persisted.
        let displayName: String
        /// The Japanese spelling. Typed input matching it, `name` or
        /// `displayName` resolves to this suggestion in any language.
        let canonicalName: String
        let colorHex: String

        var id: String { name }

        init(name: String, displayName: String? = nil, canonicalName: String? = nil, colorHex: String) {
            self.name = name
            self.displayName = displayName ?? name
            self.canonicalName = canonicalName ?? name
            self.colorHex = colorHex
        }

        /// Every spelling that selects this suggestion.
        var matchingNames: [String] {
            [name, displayName, canonicalName]
        }
    }

    static let storageKey = "usage.purpose"

    var id: Self { self }

    var title: String {
        switch self {
        case .study: String(localized: "勉強", table: "Onboarding", comment: "Legacy usage purpose: study")
        case .work: String(localized: "仕事", table: "Onboarding", comment: "Legacy usage purpose: work")
        }
    }

    var symbol: String {
        switch self {
        case .study: "book.closed.fill"
        case .work: "briefcase.fill"
        }
    }

    var summary: String {
        switch self {
        case .study: String(localized: "教科・資格の集中を積む", table: "Onboarding", comment: "Legacy usage purpose summary: study")
        case .work: String(localized: "自分の仕事の集中を積む", table: "Onboarding", comment: "Legacy usage purpose summary: work")
        }
    }

    var categoryTitle: String {
        switch self {
        case .study: String(localized: "教科・資格", table: "Onboarding", comment: "Legacy usage purpose: kind of study theme")
        case .work: String(localized: "仕事カテゴリ", table: "Onboarding", comment: "Legacy usage purpose: kind of work theme")
        }
    }

    var firstCategoryTitle: String {
        switch self {
        case .study: String(localized: "最初の教科・資格", table: "Onboarding", comment: "Legacy usage purpose: heading for the first study theme")
        case .work: String(localized: "最初の仕事カテゴリ", table: "Onboarding", comment: "Legacy usage purpose: heading for the first work theme")
        }
    }

    var setupDetail: String {
        switch self {
        case .study:
            String(
                localized: "まず1つ選んでください。資格名や科目は、瓶をひらいた後も自由に追加・編集できます。",
                table: "Onboarding",
                comment: "Legacy usage purpose: setup note for study themes"
            )
        case .work:
            String(
                localized: "まず1つ選んでください。仕事の種類は、瓶をひらいた後も自由に追加・編集できます。",
                table: "Onboarding",
                comment: "Legacy usage purpose: setup note for work themes"
            )
        }
    }

    var customFieldTitle: String {
        switch self {
        case .study: String(localized: "資格・科目名を入力", table: "Onboarding", comment: "Legacy usage purpose: title of the custom study theme field")
        case .work: String(localized: "仕事カテゴリを入力", table: "Onboarding", comment: "Legacy usage purpose: title of the custom work theme field")
        }
    }

    var customFieldPlaceholder: String {
        switch self {
        case .study: String(localized: "例：簿記2級、TOEIC", table: "Onboarding", comment: "Legacy usage purpose: study theme field placeholder. en: culturally neutral examples, not a literal translation")
        case .work: String(localized: "例：設計、レビュー", table: "Onboarding", comment: "Legacy usage purpose: work theme field placeholder")
        }
    }

    var customExamples: String {
        switch self {
        case .study: String(localized: "例：簿記2級、TOEIC", table: "Onboarding", comment: "Legacy usage purpose: study theme field placeholder. en: culturally neutral examples, not a literal translation")
        case .work: String(localized: "例：企画、開発、資料作成、顧客対応", table: "Onboarding", comment: "Legacy usage purpose: example work themes (the built-in work suggestions)")
        }
    }

    var privacyGuidance: String? {
        guard self == .work else { return nil }
        return String(
            localized: "シェアカードにテーマ名は載せません。成果メモも載せません。終了通知にもテーマ名は表示しません。案件名・顧客名・個人名などの守秘情報は入れず、「企画」「顧客対応」のような大分類がおすすめです。",
            table: "Onboarding",
            comment: "Legacy usage purpose: privacy note for work themes (theme names never appear on share cards or notifications)"
        )
    }

    var professionalUseGuidance: String? {
        guard self == .work else { return nil }
        return String(
            localized: "個人の集中を振り返るための記録です。勤怠・請求・正式な工数管理の代わりには使わないでください。",
            table: "Onboarding",
            comment: "Not for attendance, billing or official time tracking"
        )
    }

    var achievementKindsInDisplayOrder: [AchievementKind] {
        switch self {
        case .study:
            AchievementKind.allCases
        case .work:
            [.workMilestone]
                + AchievementKind.allCases.filter { $0 != .workMilestone }
        }
    }

    var presets: [CategoryPreset] {
        categoryPresets(bundle: .main)
    }

    /// `presets` in the language of `bundle` (tests resolve English).
    func categoryPresets(bundle: Bundle) -> [CategoryPreset] {
        func workPreset(_ name: String, canonical: String, colorHex: String) -> CategoryPreset {
            CategoryPreset(name: name, canonicalName: canonical, colorHex: colorHex)
        }
        switch self {
        case .study:
            // The built-in rows: saved under the canonical Japanese name of
            // their fixed ID, shown in the app's language.
            return SeedData.subjects.map {
                CategoryPreset(name: $0.name, displayName: $0.displayName(bundle: bundle), colorHex: $0.colorHex)
            }
        case .work:
            // No built-in rows: the theme is saved exactly as shown, so a
            // work suggestion picked in English is an ordinary theme named
            // "Planning". The Japanese spelling still selects it.
            // l10n-ignore-begin: canonical Japanese spellings, matched against typed input only
            return [
                workPreset(String(localized: "企画", table: "Onboarding", bundle: bundle,
                                  comment: "Work theme suggestion; saved as shown"),
                           canonical: "企画", colorHex: "#D6863A"),
                workPreset(String(localized: "開発", table: "Onboarding", bundle: bundle,
                                  comment: "Work theme suggestion; saved as shown"),
                           canonical: "開発", colorHex: Constants.Color.mathematics),
                workPreset(String(localized: "資料作成", table: "Onboarding", bundle: bundle,
                                  comment: "Work theme suggestion: making documents and slides; saved as shown"),
                           canonical: "資料作成", colorHex: Constants.Color.science),
                workPreset(String(localized: "顧客対応", table: "Onboarding", bundle: bundle,
                                  comment: "Work theme suggestion: customer support; saved as shown"),
                           canonical: "顧客対応", colorHex: Constants.Color.japanese)
            ]
            // l10n-ignore-end
        }
    }
}

/// A single, purpose-neutral catalogue used by theme setup surfaces.
///
/// `UsagePurpose` remains above as a storage compatibility type because its
/// raw values are already synchronized through CloudKit and included in data
/// exports. New UI must not branch on that legacy preference: learning and
/// work themes live in the same list and differ only by the name users choose.
enum SubjectSuggestionCatalog {
    static let presets: [UsagePurpose.CategoryPreset] = suggestions(bundle: .main)

    /// `presets` in the language of `bundle` (tests resolve English).
    static func suggestions(bundle: Bundle) -> [UsagePurpose.CategoryPreset] {
        UsagePurpose.study.categoryPresets(bundle: bundle) + UsagePurpose.work.categoryPresets(bundle: bundle)
    }

    static let inputPlaceholder = String(
        localized: "例：英語、TOEIC、企画、開発",
        table: "Onboarding",
        comment: "Theme name field placeholder. en: culturally neutral examples mixing study and work, e.g. SAT prep"
    )
    static let exampleHint = String(
        localized: "例：英語、数学、TOEIC、企画、開発、資料作成",
        table: "Onboarding",
        comment: "Example theme names under the theme name field (Settings). en: culturally neutral examples"
    )
    static let setupDetail = String(
        localized: "勉強も仕事も同じテーマ一覧で管理できます。候補を1つ選ぶか、自由に入力してください。",
        table: "Onboarding",
        comment: "Onboarding theme step: study and work themes share one list"
    )
    static let privacyGuidance = String(
        localized: "仕事に使う場合は、案件名・顧客名・個人名などの守秘情報を避け、「企画」「開発」のような大分類がおすすめです。",
        table: "Onboarding",
        comment: "Privacy note for work themes: avoid confidential names; the quoted examples are the work suggestions"
    )
    static let professionalUseGuidance = String(
        localized: "個人の集中を振り返るための記録です。勤怠・請求・正式な工数管理の代わりには使わないでください。",
        table: "Onboarding",
        comment: "Not for attendance, billing or official time tracking"
    )

    /// The suggestion a typed name means: its saved name, what it shows, or
    /// its Japanese spelling (so 「英語」 and "English" both pick the built-in
    /// preset). Resolving to the suggestion's own `name` keeps a built-in
    /// preset on its fixed-ID row whatever language the name was typed in.
    static func preset(named name: String, bundle: Bundle? = nil) -> UsagePurpose.CategoryPreset? {
        let key = SubjectNamePolicy.comparisonKey(name)
        return (bundle.map(suggestions(bundle:)) ?? presets).first { preset in
            preset.matchingNames.contains { SubjectNamePolicy.comparisonKey($0) == key }
        }
    }

    /// What a chosen theme reads as before it exists: a suggestion's shown
    /// name, or the typed name itself. Display only.
    static func displayName(forChosen name: String) -> String {
        presets.first { $0.name == name }?.displayName ?? name
    }
}

enum OnboardingThemePolicy {
    /// A built-in row may be created before setup is complete. Only a user's
    /// explicit selection or historical relationship makes it durable.
    static func shouldRetireBuiltInPreset(
        isSelected: Bool,
        hasHistory: Bool
    ) -> Bool {
        !isSelected && !hasHistory
    }

    enum BuiltInPresetChange: Equatable {
        /// Tombstone it: a sticky, synced deletion.
        case retire
        case archive
        case unarchive
        case keep
    }

    /// What finishing onboarding does to one built-in preset row that already
    /// exists. launch-06: in iCloud mode such a row can only have arrived from
    /// the user's other devices (a cloud cold launch never seeds presets), and
    /// its sessions may simply not have been imported yet. Tombstoning or
    /// archiving it would sync that decision back to every device, so iCloud
    /// mode leaves unselected presets exactly as they arrived. Local stores
    /// keep the original cleanup of rows an older version seeded.
    static func builtInPresetChange(
        isSelected: Bool,
        isArchived: Bool,
        storesInCloud: Bool,
        hasHistory: () throws -> Bool
    ) rethrows -> BuiltInPresetChange {
        if isSelected { return isArchived ? .unarchive : .keep }
        if storesInCloud { return .keep }
        if try shouldRetireBuiltInPreset(isSelected: false, hasHistory: hasHistory()) {
            return .retire
        }
        return isArchived ? .keep : .archive
    }

    /// Whether a theme that already exists takes one of the twelve slots
    /// while the user picks a first theme. It must match what finishing
    /// onboarding keeps (`builtInPresetChange`), or the picker offers a slot
    /// that completion then does not have and the chosen theme is silently
    /// skipped. A local store reclaims an unselected built-in preset without
    /// history, so that one is free; iCloud mode keeps every theme that
    /// arrived (launch-06), so every live theme counts there. `hasHistory`
    /// is read only for a local built-in preset, the one case that needs it.
    static func countsAgainstThemeLimitBeforeSelection(
        isBuiltInPreset: Bool,
        storesInCloud: Bool,
        hasHistory: @autoclosure () -> Bool
    ) -> Bool {
        if storesInCloud || !isBuiltInPreset { return true }
        return hasHistory()
    }

    /// launch-07. The one theme 「瓶をひらく」 will create. A valid name still
    /// in the text field is the user's latest intent, so it wins over a chip
    /// tapped earlier: before this, the typed name was silently dropped
    /// unless 「選択」 or Return committed it first, and the button stayed
    /// disabled while a valid name sat in the field. A name matching a
    /// suggestion resolves to that suggestion's own spelling, and a name the
    /// theme limit cannot accept leaves the committed selection in place.
    static func effectiveSelection(
        selected: Set<String>,
        pending: String,
        canChoose: (String) -> Bool
    ) -> Set<String> {
        guard SubjectNamePolicy.validationError(for: pending) == nil,
              let name = SubjectNamePolicy.validated(pending)
        else { return selected }
        let resolved = SubjectSuggestionCatalog.preset(named: name)?.name ?? name
        let key = SubjectNamePolicy.comparisonKey(resolved)
        if let committed = selected.first(where: {
            SubjectNamePolicy.comparisonKey($0) == key
        }) {
            return [committed]
        }
        guard canChoose(resolved) else { return selected }
        return [resolved]
    }
}
