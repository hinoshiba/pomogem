import XCTest
@testable import Tsumiben

final class SubjectNamePolicyTests: XCTestCase {
    func testSanitizedTrimsAndLimitsByUserVisibleCharacter() {
        let value = "  " + String(repeating: "📚", count: 45) + "\n"
        let sanitized = SubjectNamePolicy.sanitized(value)

        XCTAssertEqual(sanitized.count, SubjectNamePolicy.maximumCharacters)
        XCTAssertEqual(sanitized, String(repeating: "📚", count: 40))
    }

    func testValidationExplainsEmptyExactLimitAndOverflow() {
        XCTAssertEqual(
            SubjectNamePolicy.validationError(for: " \n "),
            .empty
        )
        XCTAssertNil(
            SubjectNamePolicy.validationError(
                for: String(repeating: "学", count: SubjectNamePolicy.maximumCharacters)
            )
        )
        XCTAssertEqual(
            SubjectNamePolicy.validationError(
                for: String(repeating: "学", count: SubjectNamePolicy.maximumCharacters + 1)
            ),
            .tooLong(excessCharacters: 1)
        )
    }

    func testComparisonKeyNormalizesCaseDiacriticsAndWidth() {
        XCTAssertEqual(
            SubjectNamePolicy.comparisonKey(" ＴＯＥＩＣ "),
            SubjectNamePolicy.comparisonKey("toeic")
        )
        XCTAssertEqual(
            SubjectNamePolicy.comparisonKey("Café"),
            SubjectNamePolicy.comparisonKey("cafe")
        )
        XCTAssertEqual(
            SubjectNamePolicy.comparisonKey("ｶﾀｶﾅ"),
            SubjectNamePolicy.comparisonKey("カタカナ")
        )
        XCTAssertEqual(
            SubjectNamePolicy.comparisonKey("がく"),
            SubjectNamePolicy.comparisonKey("か\u{3099}く")
        )
    }

    func testLegacyLongNameIsBoundedForDisplayWithoutRewritingStoredValue() {
        let legacyName = String(repeating: "長", count: 64)
        let subject = Subject(
            name: "一時名",
            colorHex: Constants.Color.english,
            sortOrder: 0
        )
        subject.name = legacyName

        XCTAssertEqual(subject.name, legacyName)
        XCTAssertEqual(subject.safeDisplayName.count, SubjectNamePolicy.maximumCharacters)

        let session = StudySession(
            startAt: .now,
            endAt: .now,
            seconds: 60,
            source: .timer,
            deviceDayKey: "2026-08-30"
        )
        session.subjectNameSnapshot = legacyName
        XCTAssertEqual(session.subjectNameSnapshot, legacyName)
        XCTAssertEqual(session.displaySubjectName.count, SubjectNamePolicy.maximumCharacters)
    }

    func testLegacyFocusSnapshotDecodeBoundsSystemSurfaceName() throws {
        struct LegacySnapshot: Encodable {
            let id: UUID
            let name: String
            let colorHex: String
        }

        let payload = LegacySnapshot(
            id: UUID(),
            name: String(repeating: "資", count: 72),
            colorHex: Constants.Color.mathematics
        )
        let decoded = try JSONDecoder().decode(
            FocusSubjectSnapshot.self,
            from: JSONEncoder().encode(payload)
        )

        XCTAssertEqual(decoded.name.count, SubjectNamePolicy.maximumCharacters)
        XCTAssertEqual(decoded.name, String(repeating: "資", count: 40))
    }

    func testRemainingCountUsesTrimmedName() {
        XCTAssertEqual(
            SubjectNamePolicy.remainingCharacters(for: "  簿記2級  "),
            SubjectNamePolicy.maximumCharacters - 4
        )
    }
}
