import XCTest
@testable import PomoGem

/// product-04 / notify-05: an outside start may do only what Home's start
/// button could, and never start a second session.
final class FocusStartEntryPolicyTests: XCTestCase {
    private func snapshot(
        isFresh: Bool = true,
        homeIsVisible: Bool = true,
        timerIsPresented: Bool = false,
        focusRecoveryIsPending: Bool = false,
        rewardChoiceIsPending: Bool = false,
        closableSurfaceIsPresented: Bool = false,
        celebrationIsPresented: Bool = false,
        hasTheme: Bool = true
    ) -> FocusStartEntryPolicy.Snapshot {
        FocusStartEntryPolicy.Snapshot(
            requestID: UUID(),
            isFresh: isFresh,
            homeIsVisible: homeIsVisible,
            timerIsPresented: timerIsPresented,
            focusRecoveryIsPending: focusRecoveryIsPending,
            rewardChoiceIsPending: rewardChoiceIsPending,
            closableSurfaceIsPresented: closableSurfaceIsPresented,
            celebrationIsPresented: celebrationIsPresented,
            hasTheme: hasTheme
        )
    }

    func testAnIdleHomeStartsTheFocus() {
        XCTAssertEqual(FocusStartEntryPolicy.decide(snapshot()), .start)
    }

    func testARunningOrRecoveringTimerIsNeverJoinedByASecondSession() {
        for state in [
            snapshot(timerIsPresented: true),
            snapshot(homeIsVisible: false, timerIsPresented: true),
            snapshot(timerIsPresented: true, closableSurfaceIsPresented: true)
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
    }

    func testAnExpiredRequestIsDroppedWhateverHomeShows() {
        for state in [
            snapshot(isFresh: false),
            snapshot(isFresh: false, homeIsVisible: false),
            snapshot(isFresh: false, timerIsPresented: true),
            snapshot(isFresh: false, celebrationIsPresented: true)
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
    }

    func testOrdinarySheetsCloseButACelebrationWaitsForThePerson() {
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

    func testWithoutAThemeNothingStarts() {
        XCTAssertEqual(
            FocusStartEntryPolicy.decide(snapshot(hasTheme: false)),
            .decline(.noTheme)
        )
    }

    func testOnlyReasonsThePersonCanActOnAreAnnounced() {
        XCTAssertNil(FocusStartEntryPolicy.message(for: .expired))
        XCTAssertNil(FocusStartEntryPolicy.message(for: .timerOnScreen))
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
