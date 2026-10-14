import XCTest
@testable import PomoGem

final class SubjectNamePolicyTests: XCTestCase {
    func testSubjectDurationDefaultsToSharedPreferenceAndKeepsSeconds() {
        let subject = Subject(name: "Reading", colorHex: Constants.Color.english, sortOrder: 0)
        XCTAssertNil(subject.defaultFocusSeconds)
        XCTAssertEqual(SubjectFocusDurationPolicy.savedDuration(
            subjectDefaultSeconds: nil, preferredSeconds: 2_700
        ), .custom(minutes: 45))
        XCTAssertEqual(SubjectFocusDurationPolicy.savedDuration(
            subjectDefaultSeconds: 95, preferredSeconds: 2_700
        ), .customSeconds(totalSeconds: 95))
        XCTAssertEqual(SubjectFocusDurationPolicy.savedDuration(
            subjectDefaultSeconds: nil, preferredSeconds: nil
        ), .twentyFiveMinutes)
    }

    func testInvalidSubjectDurationsFallBackWithoutClampingRawValues() {
        for seconds in [Int.min, -1, 0, 59, 21_601, Int.max] {
            XCTAssertEqual(SubjectFocusDurationPolicy.savedDuration(
                subjectDefaultSeconds: seconds, preferredSeconds: 3_600
            ), .sixtyMinutes)
            XCTAssertEqual(SubjectFocusDurationPolicy.savedDuration(
                subjectDefaultSeconds: seconds, preferredSeconds: seconds
            ), .twentyFiveMinutes)
        }
        for seconds in [60, 21_600] {
            XCTAssertEqual(SubjectFocusDurationPolicy.savedDuration(
                subjectDefaultSeconds: seconds, preferredSeconds: nil
            ).seconds, seconds)
        }
    }

    func testSubjectDurationRespectsEntitlementWithoutDiscardingSavedValue() {
        for duration in PomodoroDuration.freePresets {
            XCTAssertEqual(SubjectFocusDurationPolicy.availableDuration(
                subjectDefaultSeconds: duration.seconds, preferredSeconds: nil, isPro: false
            ), duration)
        }
        XCTAssertEqual(SubjectFocusDurationPolicy.availableDuration(
            subjectDefaultSeconds: 95, preferredSeconds: 3_600, isPro: false
        ), .twentyFiveMinutes)
        XCTAssertEqual(SubjectFocusDurationPolicy.availableDuration(
            subjectDefaultSeconds: 95, preferredSeconds: 3_600, isPro: true
        ), .customSeconds(totalSeconds: 95))
        XCTAssertEqual(SubjectFocusDurationPolicy.savedDuration(
            subjectDefaultSeconds: 95, preferredSeconds: 3_600
        ).seconds, 95)
        XCTAssertEqual(SubjectFocusDurationPolicy.availableDuration(
            subjectDefaultSeconds: nil, preferredSeconds: 95, isPro: false
        ), .twentyFiveMinutes)
    }

    func testSubjectDefaultMutationSelectsNewReplicaAndCanReturnToSharedDefault() throws {
        let id = UUID()
        let original = Subject(id: id, name: "Reading", colorHex: Constants.Color.english,
                               sortOrder: 0, defaultFocusSeconds: 2_700)
        let edited = Subject(id: id, name: "Reading", colorHex: Constants.Color.english,
                             sortOrder: 0, defaultFocusSeconds: 95)
        try SubjectSyncPolicy.recordUserMutation(from: edited, among: [original, edited])
        for values in [[original, edited], [edited, original]] {
            XCTAssertEqual(SubjectSyncPolicy.canonical(from: values)?.defaultFocusSeconds, 95)
        }
        edited.defaultFocusSeconds = nil
        try SubjectSyncPolicy.recordUserMutation(from: edited, among: [original, edited])
        XCTAssertTrue(SubjectSyncPolicy.canonical(from: [edited, original]) === edited)
        XCTAssertNil(SubjectSyncPolicy.canonical(from: [original, edited])?.defaultFocusSeconds)
        XCTAssertEqual(original.defaultFocusSeconds, 2_700, "Keep the other physical row as sync evidence")
    }

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
