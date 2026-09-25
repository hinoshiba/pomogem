import Foundation
import XCTest
@testable import PomoGem

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

    // MARK: settings-05 — the Ask to Buy wait is a display hint only

    private let requested = Date(timeIntervalSince1970: 1_790_000_000)

    func testApprovalWaitStartsAtThePendingAnswerAndLapsesAfterADay() {
        var hint = ProApprovalWaitHint()
        XCTAssertFalse(hint.isWaiting(at: requested))

        hint.recordRequest(at: requested)
        XCTAssertTrue(hint.isWaiting(at: requested))
        XCTAssertTrue(hint.isWaiting(at: requested.addingTimeInterval(ProApprovalWaitHint.lifetime - 1)))
        XCTAssertFalse(
            hint.isWaiting(at: requested.addingTimeInterval(ProApprovalWaitHint.lifetime)),
            "A declined or expired request sends nothing, so the hint must end by itself"
        )
        XCTAssertFalse(
            hint.isWaiting(at: requested.addingTimeInterval(-60)),
            "A clock set back before the request must not keep a wait open forever"
        )
    }

    func testAGrantAnswersAnOpenWaitOnlyOnce() {
        var hint = ProApprovalWaitHint()
        hint.recordRequest(at: requested)

        XCTAssertTrue(hint.resolveGrant(at: requested.addingTimeInterval(3_600)))
        XCTAssertNil(hint.requestedAt)
        XCTAssertFalse(hint.resolveGrant(at: requested.addingTimeInterval(3_601)),
                       "The approval notice is said once")
    }

    func testAGrantAfterTheWaitLapsedIsNotAnnouncedAsAnApproval() {
        var hint = ProApprovalWaitHint()
        hint.recordRequest(at: requested)

        XCTAssertFalse(hint.resolveGrant(at: requested.addingTimeInterval(ProApprovalWaitHint.lifetime + 1)))
        XCTAssertNil(hint.requestedAt)
    }

    func testTheWaitSurvivesARelaunchUntilItLapses() throws {
        let suite = "ProApprovalWaitHintTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(ProApprovalWaitHint.load(from: defaults, now: requested).requestedAt)

        var hint = ProApprovalWaitHint()
        hint.recordRequest(at: requested)
        hint.save(to: defaults)

        let reloaded = ProApprovalWaitHint.load(from: defaults, now: requested.addingTimeInterval(600))
        XCTAssertEqual(reloaded.requestedAt, requested)
        XCTAssertNil(
            ProApprovalWaitHint.load(
                from: defaults,
                now: requested.addingTimeInterval(ProApprovalWaitHint.lifetime + 1)
            ).requestedAt
        )

        _ = hint.resolveGrant(at: requested)
        hint.save(to: defaults)
        XCTAssertNil(defaults.object(forKey: ProApprovalWaitHint.defaultsKey))
    }
}
