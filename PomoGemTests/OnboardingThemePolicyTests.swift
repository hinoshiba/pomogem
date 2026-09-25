import XCTest
@testable import PomoGem

/// launch-07: what 「瓶をひらく」 creates when a name is still in the field.
final class OnboardingThemePolicyTests: XCTestCase {
    private let anyName: (String) -> Bool = { _ in true }

    func testValidTypedNameWinsOverAnEarlierSuggestion() {
        XCTAssertEqual(
            OnboardingThemePolicy.effectiveSelection(
                selected: ["英語"], pending: "TOEIC", canChoose: anyName),
            ["TOEIC"]
        )
    }

    func testTypedNameIsTrimmedLikeEveryOtherThemeName() {
        XCTAssertEqual(
            OnboardingThemePolicy.effectiveSelection(
                selected: [], pending: "  簿記2級　", canChoose: anyName),
            ["簿記2級"]
        )
    }

    func testEmptyOrWhitespaceFieldKeepsTheCommittedSelection() {
        for pending in ["", "   ", "\n"] {
            XCTAssertEqual(
                OnboardingThemePolicy.effectiveSelection(
                    selected: ["英語"], pending: pending, canChoose: anyName),
                ["英語"]
            )
        }
        XCTAssertEqual(
            OnboardingThemePolicy.effectiveSelection(
                selected: [], pending: "", canChoose: anyName),
            []
        )
    }

    func testTooLongNameKeepsTheCommittedSelection() {
        let tooLong = String(repeating: "あ", count: SubjectNamePolicy.maximumCharacters + 1)
        XCTAssertEqual(
            OnboardingThemePolicy.effectiveSelection(
                selected: ["英語"], pending: tooLong, canChoose: anyName),
            ["英語"]
        )
        let longest = String(repeating: "あ", count: SubjectNamePolicy.maximumCharacters)
        XCTAssertEqual(
            OnboardingThemePolicy.effectiveSelection(
                selected: ["英語"], pending: longest, canChoose: anyName),
            [longest]
        )
    }

    func testNameMatchingASuggestionUsesTheSuggestionsSpelling() {
        XCTAssertEqual(
            OnboardingThemePolicy.effectiveSelection(
                selected: ["英語"], pending: "　企画 ", canChoose: anyName),
            ["企画"]
        )
    }

    func testNameMatchingTheCommittedThemeKeepsItsSpelling() {
        XCTAssertEqual(
            OnboardingThemePolicy.effectiveSelection(
                selected: ["TOEIC"], pending: "toeic", canChoose: anyName),
            ["TOEIC"]
        )
    }

    func testNameTheThemeLimitRejectsKeepsTheCommittedSelection() {
        XCTAssertEqual(
            OnboardingThemePolicy.effectiveSelection(
                selected: ["英語"], pending: "TOEIC", canChoose: { _ in false }),
            ["英語"]
        )
    }
}
