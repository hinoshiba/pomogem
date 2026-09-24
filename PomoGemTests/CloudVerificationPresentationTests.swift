import SwiftData
import XCTest
@testable import PomoGem

/// sync-03. iCloud verification no longer hides the jar's mass or the reward
/// card.
@MainActor
final class CloudVerificationPresentationTests: XCTestCase {
    // MARK: Reward card

    func testTheRewardCardShowsFrozenValuesWhileVerifyingAndReStampsAfter() {
        typealias Policy = PostDropProjectionPolicy
        XCTAssertEqual(Policy.source(usesCloudPersistence: false, isVerificationPending: false,
            receiptWasCloudUnverified: false, receiptStampIsCurrentVerified: false,
            verifiedProjectionIsLoaded: true), .receipt, "Local-only storage has no remote blind spot")
        for receiptWasUnverified in [false, true] {
            for stampIsCurrent in [false, true] {
                XCTAssertEqual(Policy.source(usesCloudPersistence: true, isVerificationPending: true,
                    receiptWasCloudUnverified: receiptWasUnverified, receiptStampIsCurrentVerified: stampIsCurrent,
                    verifiedProjectionIsLoaded: true), .receiptWhileVerifying,
                    "While iCloud is checked the card always carries the caption")
            }
        }
        XCTAssertEqual(Policy.source(usesCloudPersistence: true, isVerificationPending: false,
            receiptWasCloudUnverified: false, receiptStampIsCurrentVerified: true,
            verifiedProjectionIsLoaded: true), .receipt, "A receipt frozen under the current projection is published")
        XCTAssertEqual(Policy.source(usesCloudPersistence: true, isVerificationPending: false,
            receiptWasCloudUnverified: false, receiptStampIsCurrentVerified: false,
            verifiedProjectionIsLoaded: true), .verifiedProjection,
            "The app's own save bumped the epoch: re-stamp instead of hiding the progress forever")
        XCTAssertEqual(Policy.source(usesCloudPersistence: true, isVerificationPending: false,
            receiptWasCloudUnverified: true, receiptStampIsCurrentVerified: false,
            verifiedProjectionIsLoaded: true), .verifiedProjection)
        XCTAssertEqual(Policy.source(usesCloudPersistence: true, isVerificationPending: false,
            receiptWasCloudUnverified: true, receiptStampIsCurrentVerified: false,
            verifiedProjectionIsLoaded: false), .receiptWhileVerifying,
            "Never an empty total while the verified page is still being read")
    }

    func testFrozenLowerBoundProgressNeverInventsAFraction() {
        let snapshot = EffortProgressPolicy.snapshot(totalGrams: 320, latestContributionGrams: 250)
        let display = EffortProgressPresentation.display(snapshot: snapshot, projectionIsLowerBound: true)
        XCTAssertNil(display.progressFraction,
                     "A receipt frozen from an incomplete projection shows the contribution, not a guessed position")
        XCTAssertTrue(display.progressLabel.contains("今回"))
    }
}
