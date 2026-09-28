import XCTest
@testable import PomoGem

/// product-04 / notify-05: an outside start may do only what Home's start
/// button could, and never start a second session.
final class FocusStartEntryPolicyTests: XCTestCase {
    private func snapshot(
        isFresh: Bool = true,
        homeIsVisible: Bool = true,
        timerIsPresented: Bool = false,
        endedBreakIsPresented: Bool = false,
        focusRecoveryIsPending: Bool = false,
        rewardChoiceIsPending: Bool = false,
        rewardDropIsInProgress: Bool = false,
        otherSurfaceIsPresented: Bool = false,
        entryFormIsPresented: Bool = false,
        closableSurfaceIsPresented: Bool = false,
        celebrationIsPresented: Bool = false,
        hasTheme: Bool = true,
        lengthIsSettled: Bool = true
    ) -> FocusStartEntryPolicy.Snapshot {
        FocusStartEntryPolicy.Snapshot(
            requestID: UUID(),
            isFresh: isFresh,
            homeIsVisible: homeIsVisible,
            timerIsPresented: timerIsPresented,
            endedBreakIsPresented: endedBreakIsPresented,
            focusRecoveryIsPending: focusRecoveryIsPending,
            rewardChoiceIsPending: rewardChoiceIsPending,
            rewardDropIsInProgress: rewardDropIsInProgress,
            otherSurfaceIsPresented: otherSurfaceIsPresented,
            entryFormIsPresented: entryFormIsPresented,
            closableSurfaceIsPresented: closableSurfaceIsPresented,
            celebrationIsPresented: celebrationIsPresented,
            hasTheme: hasTheme,
            lengthIsSettled: lengthIsSettled
        )
    }

    func testAnIdleHomeStartsTheFocus() {
        XCTAssertEqual(FocusStartEntryPolicy.decide(snapshot()), .start)
    }

    func testARunningOrRecoveringTimerIsNeverJoinedByASecondSession() {
        for state in [
            snapshot(timerIsPresented: true),
            snapshot(homeIsVisible: false, timerIsPresented: true),
            snapshot(timerIsPresented: true, closableSurfaceIsPresented: true),
            snapshot(timerIsPresented: true, entryFormIsPresented: true)
        ] {
            XCTAssertEqual(
                FocusStartEntryPolicy.decide(state),
                .decline(.timerOnScreen)
            )
        }
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(focusRecoveryIsPending: true)),
            .decline(.focusRecoveryPending)
        )
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(
                snapshot(homeIsVisible: false, focusRecoveryIsPending: true)
            ),
            .decline(.focusRecoveryPending)
        )
        // Another iPhone's timer offered while a break is over: the offer
        // is the person's to answer first.
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(
                endedBreakIsPresented: true,
                focusRecoveryIsPending: true
            )),
            .decline(.focusRecoveryPending)
        )
    }

    func testAnEndedBreakKeepsTheRequestUntilThePersonReturnsToTheJar() {
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(
                homeIsVisible: false,
                endedBreakIsPresented: true
            )),
            .wait
        )
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(endedBreakIsPresented: true)),
            .wait
        )
        // 「瓶へ戻る」 closed it: the jar is free again.
        XCTAssertEqual(FocusStartEntryPolicy.decide(snapshot()), .start)
    }

    func testAnExpiredRequestIsDroppedWhateverHomeShows() {
        for state in [
            snapshot(isFresh: false),
            snapshot(isFresh: false, homeIsVisible: false),
            snapshot(isFresh: false, timerIsPresented: true),
            snapshot(isFresh: false, endedBreakIsPresented: true),
            snapshot(isFresh: false, entryFormIsPresented: true),
            snapshot(isFresh: false, celebrationIsPresented: true),
            snapshot(isFresh: false, lengthIsSettled: false)
        ] {
            XCTAssertEqual(FocusStartEntryPolicy.decide(state), .decline(.expired))
        }
    }

    func testTheRequestWaitsWhileHomeIsCoveredByAPage() {
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(homeIsVisible: false)),
            .wait
        )
    }

    func testTheRewardChoiceIsNeverSkipped() {
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(rewardChoiceIsPending: true)),
            .decline(.rewardChoicePending)
        )
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(
                rewardChoiceIsPending: true,
                closableSurfaceIsPresented: true
            )),
            .decline(.rewardChoicePending)
        )
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(
                rewardChoiceIsPending: true,
                rewardDropIsInProgress: true
            )),
            .decline(.rewardChoicePending)
        )
    }

    func testAChoiceAlreadyMadeWaitsSilentlyForItsGemToLand() {
        // After 「N分休憩」 or 「閉じる」 the choice is made: saying
        // 「休憩の選択を終えると…」 would ask for what was already done.
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(rewardDropIsInProgress: true)),
            .wait
        )
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(
                rewardDropIsInProgress: true,
                closableSurfaceIsPresented: true
            )),
            .wait
        )
    }

    func testReadOnlySheetsCloseButACelebrationWaitsForThePerson() {
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(closableSurfaceIsPresented: true)),
            .closeSurfaces
        )
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(celebrationIsPresented: true)),
            .wait
        )
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(
                closableSurfaceIsPresented: true,
                celebrationIsPresented: true
            )),
            .wait
        )
    }

    func testAnEntryFormIsNeverClosedUnderThePersonsTyping() {
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(entryFormIsPresented: true)),
            .wait
        )
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(
                entryFormIsPresented: true,
                closableSurfaceIsPresented: true
            )),
            .wait
        )
    }

    func testAPaywallOrShareSheetOpenedAfterTheRequestDropsIt() {
        // Root closes both when it takes a request, so one on screen now was
        // the person's own choice, for example the celebration's month-label
        // link. Neither a start over it nor one after it closes.
        for state in [
            snapshot(otherSurfaceIsPresented: true),
            snapshot(otherSurfaceIsPresented: true, celebrationIsPresented: true),
            snapshot(otherSurfaceIsPresented: true, entryFormIsPresented: true),
            snapshot(otherSurfaceIsPresented: true, closableSurfaceIsPresented: true),
            snapshot(homeIsVisible: false, otherSurfaceIsPresented: true)
        ] {
            XCTAssertEqual(
                FocusStartEntryPolicy.decide(state),
                .decline(.otherSurfaceChosen)
            )
        }
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(
                timerIsPresented: true,
                otherSurfaceIsPresented: true
            )),
            .decline(.timerOnScreen)
        )
    }

    func testAStartWithoutAPresetWaitsUntilTheLengthIsKnown() {
        // A Pro user's saved custom length before StoreKit has answered:
        // Home still shows the free 25-minute placeholder.
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(lengthIsSettled: false)),
            .wait
        )
        // Still never ahead of a reason to decline.
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(hasTheme: false, lengthIsSettled: false)),
            .decline(.noTheme)
        )
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(
                rewardChoiceIsPending: true,
                lengthIsSettled: false
            )),
            .decline(.rewardChoicePending)
        )
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(
                closableSurfaceIsPresented: true,
                lengthIsSettled: false
            )),
            .closeSurfaces
        )
    }

    func testWithoutAThemeNothingStarts() {
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(hasTheme: false)),
            .decline(.noTheme)
        )
    }

    func testOnlyReasonsThePersonCanActOnAreAnnounced() {
        XCTAssertNil(FocusStartEntryPolicy.message(for: .expired))
        XCTAssertNil(FocusStartEntryPolicy.message(for: .timerOnScreen))
        XCTAssertNil(FocusStartEntryPolicy.message(for: .otherSurfaceChosen))
        XCTAssertEqual(
            FocusStartEntryPolicy.message(for: .focusRecoveryPending),
            "進行中の集中があるため、新しい集中は始めませんでした"
        )
        XCTAssertEqual(
            FocusStartEntryPolicy.message(for: .rewardChoicePending),
            "休憩の選択を終えると、集中を始められます"
        )
        XCTAssertEqual(
            FocusStartEntryPolicy.message(for: .noTheme),
            "テーマを選ぶと、集中を始められます"
        )
    }
}
