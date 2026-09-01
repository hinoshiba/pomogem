import Foundation

enum UsagePurpose: String, CaseIterable, Identifiable, Sendable {
    case study
    case work

    struct CategoryPreset: Identifiable, Hashable, Sendable {
        let name: String
        let colorHex: String

        var id: String { name }
    }

    static let storageKey = "usage.purpose"

    var id: Self { self }

    var title: String {
        switch self {
        case .study: "勉強"
        case .work: "仕事"
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
        case .study: "教科・資格の集中を積む"
        case .work: "自分の仕事の集中を積む"
        }
    }

    var categoryTitle: String {
        switch self {
        case .study: "教科・資格"
        case .work: "仕事カテゴリ"
        }
    }

    var firstCategoryTitle: String {
        switch self {
        case .study: "最初の教科・資格"
        case .work: "最初の仕事カテゴリ"
        }
    }

    var setupDetail: String {
        switch self {
        case .study:
            "まず1つ選んでください。資格名や科目は、瓶をひらいた後も自由に追加・編集できます。"
        case .work:
            "まず1つ選んでください。仕事の種類は、瓶をひらいた後も自由に追加・編集できます。"
        }
    }

    var customFieldTitle: String {
        switch self {
        case .study: "資格・科目名を入力"
        case .work: "仕事カテゴリを入力"
        }
    }

    var customFieldPlaceholder: String {
        switch self {
        case .study: "例：簿記2級、TOEIC"
        case .work: "例：設計、レビュー"
        }
    }

    var customExamples: String {
        switch self {
        case .study: "例：簿記2級、TOEIC"
        case .work: "例：企画、開発、資料作成、顧客対応"
        }
    }

    var privacyGuidance: String? {
        guard self == .work else { return nil }
        return "シェアカードにテーマ名は載せません。成果メモも載せません。ロック画面と終了通知へのテーマ名表示は設定で選べます。案件名・顧客名・個人名などの守秘情報は入れず、「企画」「顧客対応」のような大分類がおすすめです。"
    }

    var professionalUseGuidance: String? {
        guard self == .work else { return nil }
        return "個人の集中を振り返るための記録です。勤怠・請求・正式な工数管理の代わりには使わないでください。"
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
        switch self {
        case .study:
            SeedData.subjects.map {
                CategoryPreset(name: $0.name, colorHex: $0.colorHex)
            }
        case .work:
            [
                CategoryPreset(name: "企画", colorHex: "#D6863A"),
                CategoryPreset(name: "開発", colorHex: Constants.Color.mathematics),
                CategoryPreset(name: "資料作成", colorHex: Constants.Color.science),
                CategoryPreset(name: "顧客対応", colorHex: Constants.Color.japanese)
            ]
        }
    }
}
