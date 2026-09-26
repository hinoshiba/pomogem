import Foundation
import StoreKit
import XCTest
@testable import PomoGem

/// settings-02. The paywall never shows StoreKit's framework text, stays
/// quiet when the person cancels, and gives each failure its own title.
final class PaywallErrorCopyTests: XCTestCase {
    func testACancelledPromptIsSilentForEveryAction() {
        for action in [PaywallAction.purchase, .restore, .loadProduct] {
            XCTAssertNil(PaywallErrorCopy.message(for: StoreKitError.userCancelled, action: action))
        }
    }

    func testNetworkFailureSaysToCheckTheConnection() throws {
        let error = StoreKitError.networkError(URLError(.notConnectedToInternet))
        let purchase = try XCTUnwrap(PaywallErrorCopy.message(for: error, action: .purchase))
        XCTAssertEqual(purchase, "App Storeに接続できませんでした。通信状態を確認して、もう一度お試しください。")
        XCTAssertEqual(PaywallErrorCopy.message(for: error, action: .restore), purchase)
        XCTAssertEqual(
            PaywallErrorCopy.message(for: error, action: .loadProduct),
            "App Storeに接続できませんでした。通信状態を確認して、商品情報を再読み込みしてください。"
        )
        // A bare URL error reaching the paywall reads the same.
        XCTAssertEqual(
            PaywallErrorCopy.message(for: URLError(.timedOut), action: .purchase),
            purchase
        )
    }

    func testRestrictedPurchasesPointToScreenTimeRestrictions() throws {
        let message = try XCTUnwrap(
            PaywallErrorCopy.message(for: Product.PurchaseError.purchaseNotAllowed, action: .purchase)
        )
        XCTAssertTrue(message.contains("App内での購入が制限されています"), message)
        XCTAssertTrue(message.contains("コンテンツとプライバシーの制限"), message)
    }

    func testStorefrontAndProductAvailabilityHaveTheirOwnWords() throws {
        let storefront = try XCTUnwrap(
            PaywallErrorCopy.message(for: StoreKitError.notAvailableInStorefront, action: .purchase)
        )
        XCTAssertTrue(storefront.contains("国や地域"), storefront)
        let unavailable = try XCTUnwrap(
            PaywallErrorCopy.message(for: Product.PurchaseError.productUnavailable, action: .purchase)
        )
        XCTAssertTrue(unavailable.contains("現在購入できません"), unavailable)
    }

    /// `PurchaseManager` throws its own `.productUnavailable` after StoreKit
    /// has answered (an unknown product, or one that is not the Pro
    /// non-consumable), so the connection is not to blame.
    func testTheManagersUnavailableProductNeverBlamesTheConnection() throws {
        let error = PurchaseManagerError.productUnavailable(IntegrationConstants.proProductID)
        let unavailable = "この商品は現在購入できません。時間をおいて、もう一度お試しください。"
        for action in [PaywallAction.purchase, .restore] {
            let message = try XCTUnwrap(PaywallErrorCopy.message(for: error, action: action))
            XCTAssertEqual(message, unavailable, "\(action)")
            XCTAssertFalse(message.contains("通信"), message)
            XCTAssertFalse(message.contains("商品情報"), message)
        }
        XCTAssertEqual(
            PaywallErrorCopy.message(for: Product.PurchaseError.productUnavailable, action: .purchase),
            unavailable
        )
        let reload = try XCTUnwrap(PaywallErrorCopy.message(for: error, action: .loadProduct))
        XCTAssertFalse(reload.contains("通信"), reload)
    }

    func testVerificationFailureKeepsTheCuratedSentence() {
        XCTAssertEqual(
            PaywallErrorCopy.message(for: PurchaseManagerError.failedVerification, action: .restore),
            "App Storeの購入情報を確認できませんでした。時間をおいて、もう一度お試しください。"
        )
    }

    /// Nothing the paywall shows may carry a framework's own description,
    /// whatever the error: the old restore alert appended it after
    /// 「通信状態を確認して」 even for a cancel.
    func testNoMessageEchoesTheFrameworkDescription() {
        struct Opaque: LocalizedError {
            var errorDescription: String? { "The operation couldn’t be completed. (Opaque error 7.)" }
        }
        let errors: [Error] = [
            Opaque(),
            StoreKitError.unknown,
            StoreKitError.systemError(Opaque()),
            StoreKitError.networkError(URLError(.notConnectedToInternet)),
            Product.PurchaseError.purchaseNotAllowed,
            NSError(domain: "SKErrorDomain", code: 2)
        ]
        for error in errors {
            for action in [PaywallAction.purchase, .restore, .loadProduct] {
                let message = PaywallErrorCopy.message(for: error, action: action) ?? ""
                XCTAssertFalse(message.isEmpty, "\(error) \(action)")
                let frameworkText = error.localizedDescription
                if !frameworkText.isEmpty {
                    XCTAssertFalse(message.contains(frameworkText), "\(error) \(action): \(message)")
                }
                XCTAssertFalse(message.contains("operation couldn"), message)
                XCTAssertFalse(message.contains("Domain"), message)
            }
        }
    }

    func testFailureTitlesAreDistinctFromTheProductName() {
        let purchase = PaywallAlert.failure(.purchase, message: "x")
        let restore = PaywallAlert.failure(.restore, message: "x")
        XCTAssertEqual(purchase.title, "購入を完了できませんでした")
        XCTAssertEqual(restore.title, "購入を復元できませんでした")
        XCTAssertNotEqual(purchase.title, Constants.UIStrings.paywallTitle)
        XCTAssertNotEqual(PaywallAlert.nothingToRestore.title, Constants.UIStrings.paywallTitle)
        XCTAssertEqual(PaywallAlert.restored.title, Constants.UIStrings.paywallTitle)
    }

    /// settings-08. The thank-you says what the person came for now does,
    /// and the custom-duration one says the editor opens next.
    func testPurchaseSuccessNamesTheFeatureThePersonCameFor() {
        XCTAssertTrue(PaywallAlert.purchased(context: .customTimer).message.contains("集中時間を選ぶ画面が開きます"))
        XCTAssertTrue(PaywallAlert.purchased(context: .screenTimeApps).message.contains("勉強アプリ"))
        XCTAssertTrue(PaywallAlert.purchased(context: .aggregateLabels).message.contains("作った月"))
        for context in [PaywallContext.settings, .customTimer, .screenTimeApps, .aggregateLabels] {
            XCTAssertEqual(PaywallAlert.purchased(context: context).title, Constants.UIStrings.paywallTitle)
        }
    }
}
