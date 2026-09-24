import XCTest
@testable import PomoGem

final class FairnessTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    func testDeviceDayKeyChangesExactlyAtFourAM() throws {
        let threeFiftyNine = try makeDate(year: 2026, month: 8, day: 29, hour: 3, minute: 59)
        let four = try makeDate(year: 2026, month: 8, day: 29, hour: 4, minute: 0)

        XCTAssertEqual(
            FairnessPolicy.deviceDayKey(for: threeFiftyNine, timeZone: tokyo),
            "2026-08-28"
        )
        XCTAssertEqual(
            FairnessPolicy.deviceDayKey(for: four, timeZone: tokyo),
            "2026-08-29"
        )
    }

    func testManualCounterAllowsThreeThenResetsAtFourAM() throws {
        let threeFiftyNine = try makeDate(year: 2026, month: 8, day: 29, hour: 3, minute: 59)
        let four = try makeDate(year: 2026, month: 8, day: 29, hour: 4, minute: 0)
        var state = ManualCounterState()

        for expectedRemaining in [2, 1, 0] {
            let decision = FairnessPolicy.consumeManualEntry(
                state: state,
                at: threeFiftyNine,
                timeZone: tokyo
            )
            XCTAssertTrue(decision.isAllowed)
            XCTAssertEqual(decision.remainingEntries, expectedRemaining)
            state = decision.state
        }

        let denied = FairnessPolicy.consumeManualEntry(
            state: state,
            at: threeFiftyNine,
            timeZone: tokyo
        )
        XCTAssertFalse(denied.isAllowed)
        XCTAssertEqual(denied.state.usedToday, 3)

        let reset = FairnessPolicy.consumeManualEntry(
            state: denied.state,
            at: four,
            timeZone: tokyo
        )
        XCTAssertTrue(reset.isAllowed)
        XCTAssertEqual(reset.state.dayKey, "2026-08-29")
        XCTAssertEqual(reset.state.usedToday, 1)
        XCTAssertEqual(reset.remainingEntries, 2)
    }

    func testManualAvailabilityIsReadOnlyAndResetsExactlyAtFourAM() throws {
        let threeFiftyNine = try makeDate(year: 2026, month: 8, day: 29, hour: 3, minute: 59)
        let four = try makeDate(year: 2026, month: 8, day: 29, hour: 4, minute: 0)
        let persisted = ManualCounterState(dayKey: "2026-08-28", usedToday: 2)

        let beforeBoundary = FairnessPolicy.manualEntryAvailability(
            state: persisted,
            at: threeFiftyNine,
            timeZone: tokyo
        )
        XCTAssertEqual(beforeBoundary.state, persisted)
        XCTAssertEqual(beforeBoundary.remainingEntries, 1)
        XCTAssertEqual(beforeBoundary.remainingEntriesAfterSaving, 0)
        XCTAssertTrue(beforeBoundary.isAllowed)

        let afterBoundary = FairnessPolicy.manualEntryAvailability(
            state: persisted,
            at: four,
            timeZone: tokyo
        )
        XCTAssertEqual(
            afterBoundary.state,
            ManualCounterState(dayKey: "2026-08-29", usedToday: 0)
        )
        XCTAssertEqual(afterBoundary.remainingEntries, 3)
        XCTAssertEqual(afterBoundary.remainingEntriesAfterSaving, 2)
        XCTAssertTrue(afterBoundary.isAllowed)

        XCTAssertEqual(
            persisted,
            ManualCounterState(dayKey: "2026-08-28", usedToday: 2),
            "Previewing a confirmation must not consume Prefs"
        )
    }

    func testManualAvailabilityAtCapDisablesSelectionWithoutChangingCounter() throws {
        let now = try makeDate(year: 2026, month: 8, day: 29, hour: 12, minute: 0)
        let persisted = ManualCounterState(dayKey: "2026-08-29", usedToday: 3)

        let availability = FairnessPolicy.manualEntryAvailability(
            state: persisted,
            at: now,
            timeZone: tokyo
        )

        XCTAssertFalse(availability.isAllowed)
        XCTAssertEqual(availability.remainingEntries, 0)
        XCTAssertEqual(availability.remainingEntriesAfterSaving, 0)
        XCTAssertEqual(availability.state, persisted)
    }

    func testNormalBackgroundIntervalsRemainMeasuredAtOneTwelveAndTwentyFourMinutes() {
        let start = Date(timeIntervalSince1970: 10_000)
        let anchor = ClockAnchor(wallDate: start, systemUptime: 2_000)

        for elapsed in [60.0, 12 * 60.0, 24 * 60.0] {
            let integrity = FairnessPolicy.clockIntegrity(
                from: anchor,
                completionDate: start.addingTimeInterval(elapsed),
                completionUptime: anchor.systemUptime + elapsed
            )
            XCTAssertFalse(integrity.shouldDemote, "elapsed=\(elapsed)")
            XCTAssertEqual(
                FairnessPolicy.finalSource(
                    original: .timer,
                    clockIntegrity: integrity
                ),
                .timer,
                "elapsed=\(elapsed)"
            )
        }
    }

    func testClockToleranceAllowsNinetySecondsButDemotesBeyondIt() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let anchor = ClockAnchor(wallDate: start, systemUptime: 5_000)

        let exactTolerance = FairnessPolicy.clockIntegrity(
            from: anchor,
            completionDate: start.addingTimeInterval(1_590),
            completionUptime: 6_500
        )
        XCTAssertFalse(exactTolerance.shouldDemote)
        guard case let .valid(drift) = exactTolerance else {
            return XCTFail("Expected valid clock")
        }
        XCTAssertEqual(drift, 90, accuracy: 0.000_001)

        let advancedClock = FairnessPolicy.clockIntegrity(
            from: anchor,
            completionDate: start.addingTimeInterval(1_591),
            completionUptime: 6_500
        )
        XCTAssertTrue(advancedClock.shouldDemote)

        let reversedClock = FairnessPolicy.clockIntegrity(
            from: anchor,
            completionDate: start.addingTimeInterval(1_409),
            completionUptime: 6_500
        )
        XCTAssertTrue(reversedClock.shouldDemote)
    }

    func testClockCheckDetectsDeviceReboot() {
        let anchor = ClockAnchor(
            wallDate: Date(timeIntervalSince1970: 1_000),
            systemUptime: 50_000
        )
        let integrity = FairnessPolicy.clockIntegrity(
            from: anchor,
            completionDate: Date(timeIntervalSince1970: 2_500),
            completionUptime: 100
        )
        XCTAssertEqual(integrity, .uptimeReset)
        XCTAssertTrue(integrity.shouldDemote)
    }

    func testFinalClassificationDemotesEveryUnprovenTimerInterval() {
        XCTAssertEqual(
            FairnessPolicy.finalSource(
                original: .timer,
                clockIntegrity: .valid(drift: 0)
            ),
            .timer
        )
        XCTAssertEqual(
            FairnessPolicy.finalSource(
                original: .timer,
                clockIntegrity: .uptimeReset
            ),
            .timerDemoted
        )
        XCTAssertEqual(
            FairnessPolicy.finalSource(
                original: .timer,
                clockIntegrity: .unverifiable
            ),
            .timerDemoted
        )
        XCTAssertEqual(
            FairnessPolicy.finalSource(
                original: .timer,
                clockIntegrity: .changed(drift: 91)
            ),
            .timerDemoted
        )
        XCTAssertEqual(
            FairnessPolicy.finalSource(
                original: .manual,
                clockIntegrity: .changed(drift: 91)
            ),
            .manual
        )
    }

    func testCompletionFairnessUsesCapturedUptimeAcrossPersistenceRetry() throws {
        let start = Date(timeIntervalSince1970: 50_000)
        let anchor = ClockAnchor(wallDate: start, systemUptime: 10_000)
        let completion = PomodoroCompletion(
            sessionID: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(1_500),
            observedAt: start.addingTimeInterval(1_500),
            observedUptime: 11_500,
            duration: .twentyFiveMinutes,
            seconds: 1_500,
            grams: 250,
            source: .timer
        )

        let finalized = FairnessPolicy.finalizedCompletion(
            completion,
            clockAnchor: anchor
        )
        XCTAssertEqual(finalized.source, .timer)

        let restored = try JSONDecoder().decode(
            PomodoroCompletion.self,
            from: JSONEncoder().encode(finalized)
        )
        // A retry has no current-uptime input: it can only use the observation
        // captured at the actual completion boundary.
        XCTAssertEqual(
            FairnessPolicy.finalizedCompletion(restored, clockAnchor: anchor).source,
            .timer
        )
        XCTAssertEqual(restored.observedUptime, 11_500)
    }

    func testCompletionFairnessDemotesCapturedClockTamperAndTrustsLegacySource() {
        let start = Date(timeIntervalSince1970: 60_000)
        let anchor = ClockAnchor(wallDate: start, systemUptime: 20_000)
        let tampered = PomodoroCompletion(
            sessionID: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(1_500),
            observedAt: start.addingTimeInterval(1_700),
            observedUptime: 21_500,
            duration: .twentyFiveMinutes,
            seconds: 1_500,
            grams: 250,
            source: .timer
        )
        XCTAssertEqual(
            FairnessPolicy.finalizedCompletion(tampered, clockAnchor: anchor).source,
            .timerDemoted
        )

        let legacy = PomodoroCompletion(
            sessionID: UUID(),
            startedAt: start,
            endedAt: start.addingTimeInterval(1_500),
            observedAt: start.addingTimeInterval(1_500),
            duration: .twentyFiveMinutes,
            seconds: 1_500,
            grams: 250,
            source: .timer
        )
        XCTAssertEqual(
            FairnessPolicy.finalizedCompletion(legacy, clockAnchor: anchor),
            legacy
        )
    }

    func testBedrockImportTombstoneSurvivesVisibleDeletion() {
        let prefs = Prefs()
        XCTAssertTrue(FairnessPolicy.consumeBedrockImport(
            prefs: prefs,
            existingBedrockCount: 0
        ))
        XCTAssertTrue(prefs.hasEverImportedBedrock)

        // Even after the sole Bedrock model is deleted, the lifetime tombstone
        // prevents a second import.
        XCTAssertFalse(FairnessPolicy.consumeBedrockImport(
            prefs: prefs,
            existingBedrockCount: 0
        ))
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        return try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }

    func testDemotionNoticeNamesTheActualReason() {
        XCTAssertEqual(
            FocusDemotionNoticeReason.recovered(origin: .iCloud),
            .adoptedFromOtherDevice,
            "Continuing a timer from another iPhone is not a clock change"
        )
        XCTAssertEqual(FocusDemotionNoticeReason.recovered(origin: .local), .continuityLost)
        XCTAssertNil(FocusDemotionNoticeReason.detected(.valid(drift: 0.5)))
        XCTAssertEqual(FocusDemotionNoticeReason.detected(.changed(drift: 600)), .clockChanged)
        XCTAssertEqual(FocusDemotionNoticeReason.detected(.uptimeReset), .continuityLost)
        XCTAssertEqual(FocusDemotionNoticeReason.detected(.unverifiable), .continuityLost)

        XCTAssertTrue(FocusDemotionNoticeReason.clockChanged.message.contains("端末時刻"))
        XCTAssertTrue(FocusDemotionNoticeReason.adoptedFromOtherDevice.message.contains("別の端末から引き継いだ"))
        XCTAssertFalse(FocusDemotionNoticeReason.adoptedFromOtherDevice.message.contains("時刻"))
        XCTAssertFalse(FocusDemotionNoticeReason.continuityLost.message.contains("時刻"))
    }
}
