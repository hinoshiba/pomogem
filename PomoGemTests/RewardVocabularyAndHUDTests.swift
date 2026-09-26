import XCTest
@testable import PomoGem

/// The reward-moment vocabulary, the jar HUD's honest timing and the delayed
/// manual save (walk-std-08, walk-std-09, dev-D7, history-02).
@MainActor
final class RewardVocabularyAndHUDTests: XCTestCase {
    // MARK: HUD (walk-std-09)

    func testTheCorePlateAlwaysHangsBelowThePrism() {
        // Every stage width Home can produce (150...190 pt) and every prism
        // size the core can grow to.
        for dimension in stride(from: CGFloat(150), through: 190, by: 5) {
            for factor in stride(from: CGFloat(0.20), through: 0.51, by: 0.01) {
                let top = JarLifetimeCorePlateLayout.plateTopOffset(
                    dimension: dimension,
                    prismDiameterFactor: factor
                )
                XCTAssertGreaterThanOrEqual(
                    top,
                    dimension * factor / 2 + 8,
                    "dimension \(dimension), factor \(factor)"
                )
            }
        }
    }

    func testCycleChipStaysAboveTheHUDOnTallStages() {
        // Home's HUD starts 88 pt down; the chip is about 16 pt tall.
        XCTAssertEqual(
            JarAccumulationPresenceLayoutPresentation.cycleChipCenterY(
                bandY: 93.4,
                showsLifetimeCore: true
            ),
            72
        )
        XCTAssertLessThanOrEqual(
            JarAccumulationPresenceLayoutPresentation.cycleChipMaximumCenterY + 8,
            88
        )
        XCTAssertEqual(
            JarAccumulationPresenceLayoutPresentation.cycleChipCenterY(
                bandY: 40,
                showsLifetimeCore: true
            ),
            40
        )
        // Without a core the band sits near the base and is left alone.
        XCTAssertEqual(
            JarAccumulationPresenceLayoutPresentation.cycleChipCenterY(
                bandY: 380,
                showsLifetimeCore: false
            ),
            380
        )
    }

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

    // MARK: history-02

    func testManualEntryWaitsLongerForAssistiveTechnology() {
        XCTAssertEqual(
            ManualEntryUndoPolicy.window(assistiveTechnologyIsRunning: false),
            .seconds(5)
        )
        XCTAssertEqual(
            ManualEntryUndoPolicy.window(assistiveTechnologyIsRunning: true),
            .seconds(15)
        )
    }
}
