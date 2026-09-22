import Foundation
import XCTest
@testable import PomoGem

final class ScreenTimeRolloverTests: XCTestCase {
    private let midnight = Date(timeIntervalSince1970: 1_800_000_000)

    private func previousRun(lane: ScreenTimeLane = .learning, active: Bool = true) -> ScreenTimeRun {
        ScreenTimeRun(
            lane: lane,
            dayStart: midnight.addingTimeInterval(-86_400), dayEnd: midnight,
            startedAt: midnight.addingTimeInterval(-43_200), timeZoneID: "Asia/Tokyo",
            includesPastActivity: false, themeID: UUID(), active: active
        )
    }

    private func includesPast(
        _ runs: [ScreenTimeRun], lane: ScreenTimeLane = .learning,
        paused: Bool = false, subscribed: Bool = true,
        supported: Bool = true, timeZoneID: String = "Asia/Tokyo"
    ) -> Bool {
        ScreenTimeRolloverPolicy.includesPastActivity(
            lane: lane, previousRuns: runs, dayStart: midnight,
            timeZoneID: timeZoneID, learningPausedByTimer: paused,
            learningAllowedBySubscription: subscribed, supportsPastActivity: supported
        )
    }

    func testForegroundAndDelayedSchedulerUseTheSamePreviousDayContinuity() {
        let prior = previousRun()
        // Neither call needs to know whether the foreground app or extension
        // observed the day transition; both retain midnight-to-registration use.
        XCTAssertTrue(includesPast([prior]))
        XCTAssertTrue(includesPast([prior]))
        XCTAssertTrue(includesPast([previousRun(lane: .distraction)], lane: .distraction))
    }

    func testStoppedOrEditedRunCannotAuthorizeHistoricalUsage() {
        var retired = previousRun(active: false)
        // Unacknowledged receipts deliberately keep an old run in the ledger.
        // Their existence is not evidence that collection continued overnight.
        retired.highestThreshold = 3
        retired.observedAt = midnight.addingTimeInterval(-600)
        XCTAssertFalse(includesPast([retired]))
        XCTAssertFalse(includesPast([]))
        XCTAssertFalse(includesPast([previousRun(lane: .distraction)]))
    }

    func testTimerPauseAndSubscriptionRetirementCannotBackfillLearning() {
        XCTAssertFalse(includesPast([previousRun()], paused: true))
        XCTAssertFalse(includesPast([previousRun()], subscribed: false))
        // Resuming after midnight retains only an inactive pre-pause run.
        XCTAssertFalse(includesPast([previousRun(active: false)], paused: false))
        XCTAssertTrue(includesPast([previousRun(lane: .distraction)], lane: .distraction, paused: true, subscribed: false))
    }

    func testSameDayRepairAndLaterSchedulerDoNotRestartFromMidnight() {
        var current = previousRun()
        current.dayStart = midnight
        current.dayEnd = midnight.addingTimeInterval(86_400)
        current.startedAt = midnight.addingTimeInterval(1_800)
        XCTAssertFalse(includesPast([current]))
        XCTAssertFalse(includesPast([previousRun(active: false), current]))
    }

    func testTimeZoneChangeCannotReplayOverlappingCalendarUsage() {
        XCTAssertFalse(includesPast([previousRun()], timeZoneID: "America/Los_Angeles"))
        var overlapping = previousRun()
        overlapping.dayEnd = midnight.addingTimeInterval(3_600)
        XCTAssertFalse(includesPast([overlapping]))
    }

    func testEarlierOSKeepsRegistrationTimeAsObservationStart() {
        XCTAssertFalse(includesPast([previousRun()], supported: false))
    }
}
