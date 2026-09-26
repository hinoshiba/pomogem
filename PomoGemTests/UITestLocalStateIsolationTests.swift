#if DEBUG
import Foundation
import XCTest
@testable import PomoGem

/// A UI test opens an empty store. Queues in UserDefaults that name rows of an
/// earlier store must go, or Home waits forever for a gem that cannot drop.
/// Timer state must stay, because relaunch tests recover it.
final class UITestLocalStateIsolationTests: XCTestCase {
    func testForgetsStoreDerivedQueuesAndKeepsTimerState() throws {
        let suite = "PomoGemTests.ui-test-isolation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_700_000)
        let sessionID = UUID(uuidString: "33000000-0000-4000-8000-000000000001")!

        var receipt = PendingRewardReceipt(
            id: sessionID,
            createdAt: now,
            breakMinutes: 5,
            grams: 250,
            subjectName: "英語",
            colorHex: "#6CA8FF",
            weeklyCompletionCount: 1,
            kind: .normal,
            totalPebbleCount: 1,
            projectionIsLowerBound: false,
            dropPhase: .awaitingAcknowledgement
        )
        XCTAssertTrue(PendingRewardReceiptStore.insert(receipt, defaults: defaults))
        // The stuck case seen in the UI suite: acknowledged, never landed.
        XCTAssertTrue(PendingRewardReceiptStore.acknowledgeDrop(id: sessionID, defaults: defaults))
        receipt = try XCTUnwrap(PendingRewardReceiptStore.load(defaults: defaults).first)
        XCTAssertEqual(receipt.dropPhase, .awaitingLanding)
        PendingStratumCelebrationStore.insert(
            PendingStratumCelebration(
                id: UUID(), createdAt: now, pebbleCount: 10, grams: 2_500, monthLabel: "9月"
            ),
            defaults: defaults
        )
        ScreenTimeGemDropStore.append([UUID()], defaults: defaults)
        _ = FocusRestCadenceStore.record(sessionID: sessionID, contributionGrams: 2_500, defaults: defaults)
        defaults.set(sessionID.uuidString, forKey: FocusPersistence.localCompletionIDKey)
        let rest = BreakRecoveryEnvelope(
            id: UUID(),
            minutes: 5,
            endDate: now.addingTimeInterval(300),
            clockAnchor: ClockAnchor(wallDate: now, systemUptime: 1_000),
            originatingFocusSessionID: nil
        )
        FocusPersistence.saveBreak(rest, defaults: defaults, at: now)

        UITestLocalStateIsolation.forgetStateDerivedFromPreviousStores(defaults: defaults)

        XCTAssertTrue(PendingRewardReceiptStore.load(defaults: defaults).isEmpty)
        XCTAssertTrue(PendingStratumCelebrationStore.load(defaults: defaults).isEmpty)
        XCTAssertTrue(ScreenTimeGemDropStore.load(defaults: defaults).isEmpty)
        XCTAssertEqual(FocusRestCadenceStore.load(defaults: defaults).creditedGrams, 0)
        XCTAssertTrue(FocusRestCadenceStore.load(defaults: defaults).recentRecords.isEmpty)
        XCTAssertNil(defaults.string(forKey: FocusPersistence.localCompletionIDKey))
        XCTAssertEqual(
            FocusPersistence.loadBreak(defaults: defaults, at: now.addingTimeInterval(60)),
            rest,
            "A break is timer state; relaunch tests rely on recovering it"
        )
    }

    /// A pending completion from a test that ended during its alarm must not
    /// open the next test on the save-failure screen. The test's own
    /// relaunches keep it, because relaunch tests recover that timer.
    func testANewUITestForgetsTheEarlierTestsTimerButItsOwnRelaunchKeepsIt() throws {
        let defaults = UserDefaults.standard
        let savedScenario = defaults.string(forKey: UITestLocalStateIsolation.scenarioDefaultsKey)
        addTeardownBlock {
            FocusPersistence.clear()
            FocusPersistence.clearBreak()
            TimerCompletionAlertAcknowledgementStore.removeAll()
            UITestLocalStateIsolation.forgetStateDerivedFromPreviousStores()
            if let savedScenario {
                defaults.set(savedScenario, forKey: UITestLocalStateIsolation.scenarioDefaultsKey)
            } else {
                defaults.removeObject(forKey: UITestLocalStateIsolation.scenarioDefaultsKey)
            }
        }
        let key = UITestLocalStateIsolation.scenarioEnvironmentKey
        let now = Date(timeIntervalSince1970: 1_800_800_000)
        let sessionID = UUID(uuidString: "33000000-0000-4000-8000-000000000002")!

        func leaveATestBehind() throws {
            var engine = PomodoroEngine(selectedDuration: .twentyFiveMinutes)
            try engine.startFocus(isPro: false, now: now, sessionID: sessionID)
            FocusPersistence.save(
                engine,
                subject: FocusSubjectSnapshot(id: UUID(), name: "英語", colorHex: "#6CA8FF"),
                clockAnchor: ClockAnchor(wallDate: now, systemUptime: 1_000)
            )
            DeferredFocusCompletionStore.mark(sessionID: sessionID)
            TimerCompletionAlertAcknowledgementStore.mark(sessionID: sessionID)
            FocusPersistence.saveBreak(
                BreakRecoveryEnvelope(
                    id: UUID(),
                    minutes: 5,
                    endDate: now.addingTimeInterval(300),
                    clockAnchor: ClockAnchor(wallDate: now, systemUptime: 1_000),
                    originatingFocusSessionID: nil
                ),
                at: now
            )
            defaults.set(true, forKey: FocusPersistence.interruptedFlagKey)
            FocusRestCadenceStore.record(sessionID: sessionID, contributionGrams: 250)
        }

        XCTAssertTrue(UITestLocalStateIsolation.beginScenarioIfNeeded(environment: [key: "test-a"]))
        try leaveATestBehind()

        // Test A relaunches its own app: everything stays for it to recover.
        XCTAssertFalse(UITestLocalStateIsolation.beginScenarioIfNeeded(environment: [key: "test-a"]))
        XCTAssertNotNil(FocusPersistence.load())
        XCTAssertEqual(DeferredFocusCompletionStore.sessionID(), sessionID)

        // No scenario (an ordinary Debug or Release-like launch): untouched.
        XCTAssertFalse(UITestLocalStateIsolation.beginScenarioIfNeeded(environment: [:]))
        XCTAssertNotNil(FocusPersistence.load())

        // Test B's first launch starts clean.
        XCTAssertTrue(UITestLocalStateIsolation.beginScenarioIfNeeded(environment: [key: "test-b"]))
        XCTAssertNil(FocusPersistence.load())
        XCTAssertNil(DeferredFocusCompletionStore.sessionID())
        XCTAssertFalse(TimerCompletionAlertAcknowledgementStore.contains(sessionID: sessionID))
        XCTAssertNil(FocusPersistence.loadBreak(at: now.addingTimeInterval(60)))
        XCTAssertFalse(defaults.bool(forKey: FocusPersistence.interruptedFlagKey))
        XCTAssertTrue(FocusRestCadenceStore.load().recentRecords.isEmpty)
        XCTAssertEqual(defaults.string(forKey: UITestLocalStateIsolation.scenarioDefaultsKey), "test-b")
    }
}
#endif
