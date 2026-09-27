import Foundation
import XCTest
@testable import PomoGem

/// settings-04. The paywall leads with what the person came for, says what
/// stays free, and the fusion sheet's month-label link is offered once.
final class PaywallPresentationTests: XCTestCase {
    func testTheEntryPointsFeatureComesFirstAndOnlyThenIsHighlighted() {
        XCTAssertEqual(
            PaywallFeatureKind.ordered(for: .settings),
            [.customDuration, .monthLabel, .studyApps]
        )
        XCTAssertFalse(PaywallFeatureKind.highlights(.settings))

        XCTAssertEqual(PaywallFeatureKind.ordered(for: .customTimer).first, .customDuration)
        XCTAssertEqual(
            PaywallFeatureKind.ordered(for: .aggregateLabels),
            [.monthLabel, .customDuration, .studyApps]
        )
        XCTAssertEqual(
            PaywallFeatureKind.ordered(for: .screenTimeApps),
            [.studyApps, .customDuration, .monthLabel]
        )
        for context in [PaywallContext.customTimer, .aggregateLabels, .screenTimeApps] {
            XCTAssertTrue(PaywallFeatureKind.highlights(context))
            XCTAssertEqual(Set(PaywallFeatureKind.ordered(for: context)), Set(PaywallFeatureKind.allCases))
        }
    }

    /// The timer row names every free preset beside the Pro range, so nobody
    /// reads the paywall as the free timers going away.
    func testTheTimerRowNamesEveryFreePreset() {
        let detail = PaywallFeatureKind.customDuration.detail
        XCTAssertTrue(detail.hasPrefix("無料の"), detail)
        let freeMinutes = IntegrationConstants.freeFocusDurations
            .map { $0 / Constants.Timer.secondsPerMinute }
            .sorted()
        XCTAssertEqual(freeMinutes, [25, 45, 60, 90])
        XCTAssertTrue(
            detail.contains(freeMinutes.map(String.init).joined(separator: "・") + "分"),
            detail
        )
        XCTAssertTrue(detail.contains(Constants.UIStrings.customDurationRange), detail)
        XCTAssertTrue(PaywallFeatureKind.studyApps.detail.contains("無料は5つまで"))
        XCTAssertEqual(ScreenTimePolicy.freeLearningApplicationLimit, 5)
    }

    func testTheMonthLabelLinkIsOfferedOnceToAKnownFreeUser() {
        let first = UUID()
        let second = UUID()

        XCTAssertTrue(MonthLabelHintPolicy.offersHint(
            isPro: false, entitlementsResolved: true, alreadyOffered: false,
            hintCelebrationID: nil, celebrationID: first
        ))
        // Once shown, it stays on that sheet while it is open…
        XCTAssertTrue(MonthLabelHintPolicy.offersHint(
            isPro: false, entitlementsResolved: true, alreadyOffered: true,
            hintCelebrationID: first, celebrationID: first
        ))
        // …and never appears on another celebration, now or after a relaunch.
        XCTAssertFalse(MonthLabelHintPolicy.offersHint(
            isPro: false, entitlementsResolved: true, alreadyOffered: true,
            hintCelebrationID: first, celebrationID: second
        ))
        XCTAssertFalse(MonthLabelHintPolicy.offersHint(
            isPro: false, entitlementsResolved: true, alreadyOffered: true,
            hintCelebrationID: nil, celebrationID: second
        ))
    }

    func testTheMonthLabelLinkNeverReachesProOrAnUnknownEntitlement() {
        let id = UUID()
        XCTAssertFalse(MonthLabelHintPolicy.offersHint(
            isPro: true, entitlementsResolved: true, alreadyOffered: false,
            hintCelebrationID: nil, celebrationID: id
        ))
        XCTAssertFalse(MonthLabelHintPolicy.offersHint(
            isPro: true, entitlementsResolved: true, alreadyOffered: true,
            hintCelebrationID: id, celebrationID: id
        ), "Buying Pro while the sheet is open removes the link")
        XCTAssertFalse(MonthLabelHintPolicy.offersHint(
            isPro: false, entitlementsResolved: false, alreadyOffered: false,
            hintCelebrationID: nil, celebrationID: id
        ), "Until StoreKit answers, a Pro user reads as free")
    }
}
