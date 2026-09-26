import XCTest
@testable import PomoGem

/// The reward-moment vocabulary, the jar HUD's honest timing and the delayed
/// manual save (walk-std-08, walk-std-09, dev-D7, history-02).
@MainActor
final class RewardVocabularyAndHUDTests: XCTestCase {
    // MARK: dev-D7

    func testTheJarReadoutCountsAGemWhenItLands() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        func session(minutesAgo: Double) -> StudySession {
            StudySession(
                startAt: end.addingTimeInterval(-minutesAgo * 60 - 1_500),
                endAt: end.addingTimeInterval(-minutesAgo * 60),
                seconds: 1_500,
                source: .timer,
                grams: 250,
                deviceDayKey: "landed-totals"
            )
        }
        let earlier = session(minutesAgo: 60)
        let justCompleted = session(minutesAgo: 0)
        let loose = [justCompleted, earlier]

        XCTAssertEqual(
            HomeProjectionPolicy.landedTotals(
                roots: [],
                looseSessions: loose,
                unlandedSessionIDs: [justCompleted.id]
            ),
            HomeProjectionPolicy.Totals(grams: 250, pebbleCount: 1),
            "Behind the completion card, the jar still reads what it holds"
        )
        XCTAssertEqual(
            HomeProjectionPolicy.landedTotals(
                roots: [],
                looseSessions: loose,
                unlandedSessionIDs: []
            ),
            HomeProjectionPolicy.totals(roots: [], looseSessions: loose),
            "Once it lands, the readout is the full total again"
        )
        XCTAssertEqual(
            HomeProjectionPolicy.landedTotals(
                roots: [],
                looseSessions: loose,
                unlandedSessionIDs: [UUID()]
            ),
            HomeProjectionPolicy.totals(roots: [], looseSessions: loose),
            "A receipt whose session is not a loose gem changes nothing"
        )
    }
}
