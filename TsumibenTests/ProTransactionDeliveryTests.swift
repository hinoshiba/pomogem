import XCTest
@testable import Tsumiben

final class ProTransactionDeliveryTests: XCTestCase {
    func testVerifiedProChangeIsAppliedBeforeTransactionFinishes() async {
        var events: [String] = []

        let processed = await ProTransactionDelivery.process(
            productID: IntegrationConstants.proProductID,
            applyEntitlementChange: {
                events.append("apply")
            },
            finish: {
                events.append("finish")
            }
        )

        XCTAssertTrue(processed)
        XCTAssertEqual(events, ["apply", "finish"])
    }

    func testUnknownProductIsNotAppliedOrFinished() async {
        var events: [String] = []

        let processed = await ProTransactionDelivery.process(
            productID: "com.example.unknown",
            applyEntitlementChange: {
                events.append("apply")
            },
            finish: {
                events.append("finish")
            }
        )

        XCTAssertFalse(processed)
        XCTAssertTrue(events.isEmpty)
    }
}
