import XCTest
@testable import PomoGem

final class AchievementNotePolicyTests: XCTestCase {
    func testSavedNameKeepsInnerSpacesAndTrimsOnlyTheEnds() {
        XCTAssertEqual(AchievementStone.sanitizedNote("TOEIC 800点"), "TOEIC 800点")
        XCTAssertEqual(AchievementStone.sanitizedNote("英検　準1級"), "英検　準1級", "A full-width space is part of the name")
        XCTAssertEqual(AchievementStone.sanitizedNote("  基本情報 合格　\n"), "基本情報 合格")
    }

    func testCountIgnoresOnlyLeadingAndTrailingWhitespace() {
        XCTAssertEqual(AchievementNotePolicy.characterCount(for: " 英検 準1級　"), 6)
        XCTAssertEqual(AchievementNotePolicy.statusMessage(for: ""), "あと40文字入力できます。")
        XCTAssertEqual(AchievementNotePolicy.statusMessage(for: "TOEIC "), "あと35文字入力できます。")
        XCTAssertEqual(AchievementNotePolicy.shortStatus(for: "TOEIC 800点"), "あと30文字")
    }

    func testTheLimitIsExplainedBeforeSavingAndEnforcedWhenSaving() {
        let forty = String(repeating: "あ", count: 40)
        XCTAssertFalse(AchievementNotePolicy.isTooLong(forty))
        XCTAssertEqual(AchievementNotePolicy.statusMessage(for: forty), "あと0文字入力できます。")

        let fortyTwo = forty + "いう"
        XCTAssertTrue(AchievementNotePolicy.isTooLong(fortyTwo))
        XCTAssertEqual(AchievementNotePolicy.excessCharacters(for: fortyTwo), 2)
        XCTAssertEqual(AchievementNotePolicy.statusMessage(for: fortyTwo), "40文字以内で入力してください（2文字超過）。")
        XCTAssertEqual(AchievementNotePolicy.shortStatus(for: fortyTwo), "2文字超過")
        XCTAssertEqual(AchievementStone.sanitizedNote(fortyTwo), forty, "Saving stays bounded even without the UI check")
    }
}
