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

    // MARK: settings-05 — who announces an approval, and when it is seen

    /// Only a grant nothing on screen asked for is announced: the paywall's
    /// own purchase and restore alerts already say Pro is on.
    func testOnlyGrantsNobodyAskedForOnScreenAnnounceAnApproval() {
        let announcing = ProGrantPath.allCases.filter(\.announcesAnsweredWait)
        XCTAssertEqual(announcing, [.transactionUpdate, .launchReconciliation, .entitlementRefresh])
        XCTAssertFalse(ProGrantPath.purchase.announcesAnsweredWait)
        XCTAssertFalse(ProGrantPath.restore.announcesAnsweredWait)
    }

    func testAPendingAnswerOpensAWaitThatNeverReadsAsPro() {
        var state = ProApprovalWaitState()
        XCTAssertFalse(state.isAwaitingApproval(isPro: false, at: requested))

        state.recordPendingRequest(at: requested)
        XCTAssertTrue(state.isAwaitingApproval(isPro: false, at: requested.addingTimeInterval(60)))
        XCTAssertFalse(
            state.isAwaitingApproval(isPro: true, at: requested.addingTimeInterval(60)),
            "Once Pro is on, nothing reads as waiting"
        )
        XCTAssertFalse(
            state.isAwaitingApproval(isPro: false, at: requested.addingTimeInterval(ProApprovalWaitHint.lifetime + 1)),
            "The hint lapses by itself; it is never evidence of a purchase"
        )
        XCTAssertFalse(state.hasGrantNotice, "A request alone owes no notice")
    }

    /// The Ask to Buy approval arrives through `Transaction.updates`: the
    /// person hears about it exactly once.
    func testAnApprovalFromTransactionUpdatesIsAnnouncedExactlyOnce() {
        var state = ProApprovalWaitState()
        state.recordPendingRequest(at: requested)

        state.proGranted(via: .transactionUpdate, at: requested.addingTimeInterval(3_600))
        XCTAssertNil(state.hint.requestedAt, "The wait ends with the grant")
        XCTAssertTrue(state.hasGrantNotice)
        XCTAssertTrue(state.consumeGrantNotice(whenVisible: true))
        XCTAssertFalse(state.consumeGrantNotice(whenVisible: true), "Said once")

        // The same approval seen again by the next entitlement pass.
        state.proGranted(via: .entitlementRefresh, at: requested.addingTimeInterval(3_700))
        XCTAssertFalse(state.hasGrantNotice, "A second sighting of the grant is not a second approval")
    }

    func testTheSheetsOwnPurchaseAndRestoreEndTheWaitWithoutANotice() {
        for path in [ProGrantPath.purchase, .restore] {
            var state = ProApprovalWaitState()
            state.recordPendingRequest(at: requested)
            state.proGranted(via: path, at: requested.addingTimeInterval(600))
            XCTAssertNil(state.hint.requestedAt, "\(path)")
            XCTAssertFalse(state.hasGrantNotice, "\(path): the paywall's own alert already said so")
            XCTAssertFalse(state.isAwaitingApproval(isPro: false, at: requested.addingTimeInterval(601)))

            // The listener then sees the same grant: the wait is already over.
            state.proGranted(via: .transactionUpdate, at: requested.addingTimeInterval(602))
            XCTAssertFalse(state.hasGrantNotice, "\(path) then updates must not double the message")
        }
    }

    func testAGrantWithNoOpenWaitIsNeverAnnouncedAsAnApproval() {
        for path in ProGrantPath.allCases {
            var fresh = ProApprovalWaitState()
            fresh.proGranted(via: path, at: requested)
            XCTAssertFalse(fresh.hasGrantNotice, "\(path): an ordinary purchase or restore on another device")

            var lapsed = ProApprovalWaitState()
            lapsed.recordPendingRequest(at: requested)
            lapsed.proGranted(via: path, at: requested.addingTimeInterval(ProApprovalWaitHint.lifetime + 1))
            XCTAssertFalse(lapsed.hasGrantNotice, "\(path): the wait had lapsed")
        }
    }

    /// The toast is drawn beneath every sheet and cover. An approval that
    /// lands during a focus stays owed until the timer has closed.
    func testTheNoticeSurvivesWhileTheFocusTimerCoversTheToast() {
        var state = ProApprovalWaitState()
        state.recordPendingRequest(at: requested)
        state.proGranted(via: .transactionUpdate, at: requested.addingTimeInterval(900))

        let underTimer = ProApprovalNoticeVisibility.quietHome.with { $0.focusPresentationIsActive = true; $0.rootPresentsModal = true }
        for _ in 0..<3 {
            XCTAssertFalse(state.consumeGrantNotice(whenVisible: underTimer.toastIsVisible))
        }
        XCTAssertTrue(state.hasGrantNotice, "Still owed once the timer closes")

        XCTAssertTrue(state.consumeGrantNotice(whenVisible: ProApprovalNoticeVisibility.quietHome.toastIsVisible))
        XCTAssertFalse(state.hasGrantNotice)
    }

    func testEveryCoverSheetAlertOrOtherToastHoldsTheNotice() {
        XCTAssertTrue(ProApprovalNoticeVisibility.quietHome.toastIsVisible)
        let blockers: [(String, (inout ProApprovalNoticeVisibility) -> Void)] = [
            ("app in the background", { $0.appIsActive = false }),
            ("any sheet, cover or alert over the root", { $0.rootPresentsModal = true }),
            ("focus timer requested", { $0.focusPresentationIsActive = true }),
            ("paywall", { $0.paywallPresented = true }),
            ("share composer", { $0.sharePresented = true }),
            ("recovered focus or break", { $0.recoveryCoverPresented = true }),
            ("another toast", { $0.anotherToastIsShowing = true })
        ]
        for (name, block) in blockers {
            XCTAssertFalse(ProApprovalNoticeVisibility.quietHome.with(block).toastIsVisible, name)
        }
    }
}

private extension ProApprovalNoticeVisibility {
    static let quietHome = ProApprovalNoticeVisibility(
        appIsActive: true,
        rootPresentsModal: false,
        focusPresentationIsActive: false,
        paywallPresented: false,
        sharePresented: false,
        recoveryCoverPresented: false,
        anotherToastIsShowing: false
    )

    func with(_ change: (inout ProApprovalNoticeVisibility) -> Void) -> ProApprovalNoticeVisibility {
        var copy = self
        change(&copy)
        return copy
    }
}
