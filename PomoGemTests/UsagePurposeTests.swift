import XCTest
@testable import PomoGem

final class UsagePurposeTests: XCTestCase {
    func testUnifiedSuggestionCatalogMixesLearningAndWorkWithoutDuplicates() {
        let names = SubjectSuggestionCatalog.presets.map(\.name)
        XCTAssertEqual(
            names,
            ["英語", "数学", "国語", "理科", "社会", "企画", "開発", "資料作成", "顧客対応"]
        )
        XCTAssertEqual(
            Set(names.map(SubjectNamePolicy.comparisonKey)).count,
            names.count
        )
        XCTAssertTrue(names.allSatisfy {
            SubjectNamePolicy.validated($0) != nil
        })
    }

    func testUnifiedSuggestionLookupUsesSubjectNameNormalization() {
        XCTAssertEqual(
            SubjectSuggestionCatalog.preset(named: "　企画　")?.name,
            "企画"
        )
        XCTAssertNil(SubjectSuggestionCatalog.preset(named: "TOEIC"))
    }

    func testUnifiedGuidanceKeepsProfessionalPrivacyBoundariesVisible() {
        XCTAssertTrue(SubjectSuggestionCatalog.privacyGuidance.contains("案件名"))
        XCTAssertTrue(SubjectSuggestionCatalog.privacyGuidance.contains("顧客名"))
        XCTAssertTrue(SubjectSuggestionCatalog.privacyGuidance.contains("個人名"))
        XCTAssertTrue(SubjectSuggestionCatalog.professionalUseGuidance.contains("勤怠"))
        XCTAssertTrue(SubjectSuggestionCatalog.professionalUseGuidance.contains("請求"))
        XCTAssertTrue(SubjectSuggestionCatalog.professionalUseGuidance.contains("工数管理"))
    }

    func testOnboardingRetiresOnlyUnselectedHistoryFreeBuiltIns() {
        XCTAssertTrue(OnboardingThemePolicy.shouldRetireBuiltInPreset(
            isSelected: false,
            hasHistory: false
        ))
        XCTAssertFalse(OnboardingThemePolicy.shouldRetireBuiltInPreset(
            isSelected: true,
            hasHistory: false
        ))
        XCTAssertFalse(OnboardingThemePolicy.shouldRetireBuiltInPreset(
            isSelected: false,
            hasHistory: true
        ))
        XCTAssertTrue(OnboardingThemePolicy.countsAgainstThemeLimitBeforeSelection(
            isBuiltInPreset: false,
            hasHistory: false
        ))
        XCTAssertFalse(OnboardingThemePolicy.countsAgainstThemeLimitBeforeSelection(
            isBuiltInPreset: true,
            hasHistory: false
        ))
        XCTAssertTrue(OnboardingThemePolicy.countsAgainstThemeLimitBeforeSelection(
            isBuiltInPreset: true,
            hasHistory: true
        ))
    }

    func testEveryPurposeHasUniqueValidPresets() {
        for purpose in UsagePurpose.allCases {
            let names = purpose.presets.map(\.name)
            XCTAssertFalse(names.isEmpty)
            XCTAssertEqual(
                Set(names.map(SubjectNamePolicy.comparisonKey)).count,
                names.count
            )
            XCTAssertTrue(names.allSatisfy { SubjectNamePolicy.validated($0) != nil })
        }
    }

    func testWorkPresetsUseBroadNonConfidentialCategories() {
        XCTAssertEqual(
            UsagePurpose.work.presets.map(\.name),
            ["企画", "開発", "資料作成", "顧客対応"]
        )
        let guidance = try? XCTUnwrap(UsagePurpose.work.privacyGuidance)
        XCTAssertTrue(guidance?.contains("シェアカード") == true)
        XCTAssertTrue(guidance?.contains("テーマ名は載せません") == true)
        XCTAssertTrue(guidance?.contains("終了通知にもテーマ名は表示しません") == true)
        XCTAssertFalse(guidance?.contains("Live Activity") == true)
        XCTAssertTrue(guidance?.contains("案件名") == true)
        XCTAssertTrue(guidance?.contains("顧客名") == true)
        let professionalGuidance = try? XCTUnwrap(
            UsagePurpose.work.professionalUseGuidance
        )
        XCTAssertTrue(professionalGuidance?.contains("勤怠") == true)
        XCTAssertTrue(professionalGuidance?.contains("請求") == true)
        XCTAssertTrue(professionalGuidance?.contains("工数管理") == true)
        XCTAssertNil(UsagePurpose.study.privacyGuidance)
        XCTAssertNil(UsagePurpose.study.professionalUseGuidance)
    }

    func testRawValuesRemainStableForStoredPreference() {
        XCTAssertEqual(UsagePurpose.study.rawValue, "study")
        XCTAssertEqual(UsagePurpose.work.rawValue, "work")
    }

    func testWorkMilestoneIsAvailableWithDedicatedCopy() {
        XCTAssertTrue(AchievementKind.allCases.contains(.workMilestone))
        XCTAssertEqual(AchievementKind.workMilestone.title, "仕事の節目")
        XCTAssertFalse(AchievementKind.workMilestone.detail.isEmpty)
        XCTAssertFalse(AchievementKind.workMilestone.notePlaceholder.isEmpty)
    }

    func testAchievementOrderMatchesUsagePurpose() {
        XCTAssertEqual(
            UsagePurpose.study.achievementKindsInDisplayOrder,
            [.perfectScore, .examPass, .workMilestone]
        )
        XCTAssertEqual(
            UsagePurpose.work.achievementKindsInDisplayOrder,
            [.workMilestone, .perfectScore, .examPass]
        )
    }
}
