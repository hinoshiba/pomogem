import Foundation
import XCTest
@testable import Tsumiben

final class ProTransactionDeliveryTests: XCTestCase {
    func testVerifiedProChangeIsAppliedBeforeTransactionFinishes() async {
        var events: [String] = []
        let decision = ProTransactionDelivery.decision(
            isVerified: true,
            productID: IntegrationConstants.proProductID,
            productType: .nonConsumable,
            revocationDate: nil,
            isUpgraded: false
        )

        let processed = await ProTransactionDelivery.process(
            decision: decision,
            applyEntitlementChange: { receivedDecision in
                events.append("apply:\(receivedDecision)")
            },
            finish: {
                events.append("finish")
            }
        )

        XCTAssertTrue(processed)
        XCTAssertEqual(decision, .grant)
        XCTAssertEqual(events, ["apply:grant", "finish"])
    }

    func testUnknownProductIsNotAppliedOrFinished() async {
        var events: [String] = []
        let decision = ProTransactionDelivery.decision(
            isVerified: true,
            productID: "com.example.unknown",
            productType: .nonConsumable,
            revocationDate: nil,
            isUpgraded: false
        )

        let processed = await ProTransactionDelivery.process(
            decision: decision,
            applyEntitlementChange: { _ in
                events.append("apply")
            },
            finish: {
                events.append("finish")
            }
        )

        XCTAssertFalse(processed)
        XCTAssertEqual(decision, .ignoreUnknownProduct)
        XCTAssertTrue(events.isEmpty)
    }

    func testUnverifiedTransactionIsNeitherGrantedNorFinished() async {
        var events: [String] = []
        let decision = ProTransactionDelivery.decision(
            isVerified: false,
            productID: IntegrationConstants.proProductID,
            productType: .nonConsumable,
            revocationDate: nil,
            isUpgraded: false
        )

        let processed = await ProTransactionDelivery.process(
            decision: decision,
            applyEntitlementChange: { _ in events.append("apply") },
            finish: { events.append("finish") }
        )

        XCTAssertEqual(decision, .rejectUnverified)
        XCTAssertFalse(processed)
        XCTAssertTrue(events.isEmpty)
    }

    func testRevokedAndUpgradedTransactionsReconcileWithoutGranting() {
        let revoked = ProTransactionDelivery.decision(
            isVerified: true,
            productID: IntegrationConstants.proProductID,
            productType: .nonConsumable,
            revocationDate: Date(timeIntervalSince1970: 1),
            isUpgraded: false
        )
        let upgraded = ProTransactionDelivery.decision(
            isVerified: true,
            productID: IntegrationConstants.proProductID,
            productType: .nonConsumable,
            revocationDate: nil,
            isUpgraded: true
        )

        XCTAssertEqual(revoked, .reconcileWithoutGrant)
        XCTAssertEqual(upgraded, .reconcileWithoutGrant)
        XCTAssertTrue(revoked.shouldAcknowledge)
        XCTAssertTrue(upgraded.shouldAcknowledge)
    }

    func testMisconfiguredConsumableIsNeitherGrantedNorFinished() async {
        var events: [String] = []
        let decision = ProTransactionDelivery.decision(
            isVerified: true,
            productID: IntegrationConstants.proProductID,
            productType: .consumable,
            revocationDate: nil,
            isUpgraded: false
        )

        let processed = await ProTransactionDelivery.process(
            decision: decision,
            applyEntitlementChange: { _ in events.append("apply") },
            finish: { events.append("finish") }
        )

        XCTAssertEqual(decision, .rejectInvalidProductType)
        XCTAssertFalse(processed)
        XCTAssertTrue(events.isEmpty)
    }

    func testFinishGateClaimsEachTransactionOnlyOncePerProcess() {
        var gate = ProTransactionFinishGate()

        XCTAssertTrue(gate.claim(42))
        XCTAssertFalse(gate.claim(42))
        XCTAssertTrue(gate.claim(43))
        XCTAssertEqual(gate.claimedTransactionIDs, [42, 43])
    }
}
