import Foundation
import StoreKit
import SwiftUI

/// What the paywall was doing when StoreKit answered with an error. The same
/// failure reads differently after a purchase, a restore or a catalog load.
enum PaywallAction: Equatable, Sendable {
    case purchase
    case restore
    case loadProduct
}

/// settings-05. Shown wherever the person is when a purchase that waited for
/// approval (Ask to Buy) is granted. Without it Pro turned on silently,
/// possibly hours after the request.
struct ProApprovalNoticeModifier: ViewModifier {
    let router: AppRouter
    @State private var purchase = PurchaseManager.shared

    func body(content: Content) -> some View {
        content
            .onAppear(perform: announceIfNeeded)
            .onChange(of: purchase.hasApprovalGrantNotice) { _, _ in announceIfNeeded() }
    }

    private func announceIfNeeded() {
        guard purchase.consumeApprovalGrantNotice() else { return }
        router.showToast(
            String(localized: "ポモジェムProが使えるようになりました", table: "Paywall", comment: "Toast: an approved (Ask to Buy) Pro purchase arrived"),
            symbol: "checkmark.seal.fill"
        )
    }
}

/// One alert on the paywall. Failures carry their own title, so a failed
/// payment never sits under the same 「ポモジェムPro」 heading as a success.
struct PaywallAlert: Equatable {
    let title: String
    let message: String

    static func failure(_ action: PaywallAction, message: String) -> PaywallAlert {
        let title = switch action {
        case .restore:
            String(localized: "購入を復元できませんでした", table: "Paywall", comment: "Paywall alert title: restoring purchases failed")
        case .purchase, .loadProduct:
            String(localized: "購入を完了できませんでした", table: "Paywall", comment: "Paywall alert title: the purchase failed")
        }
        return PaywallAlert(title: title, message: message)
    }

    /// settings-08. After a purchase, say what just opened up for the thing
    /// the person came for, and what closing the sheet leads to.
    static func purchased(context: PaywallContext) -> PaywallAlert {
        let message = switch context {
        case .customTimer:
            // Home and Settings both reopen their duration editor.
            String(
                localized: "ポモジェムProが使えるようになりました。閉じると、集中時間を選ぶ画面が開きます。",
                table: "Paywall",
                comment: "Paywall alert after buying from the custom duration control; the editor opens next"
            )
        case .screenTimeApps:
            String(
                localized: "ポモジェムProが使えるようになりました。勉強アプリを数の制限なく選べます。",
                table: "Paywall",
                comment: "Paywall alert after buying from Screen Time's study-app limit"
            )
        case .aggregateLabels:
            String(
                localized: "ポモジェムProが使えるようになりました。結晶に、作った月が表示されます。",
                table: "Paywall",
                comment: "Paywall alert after buying from the crystal month-label hint"
            )
        case .settings:
            String(
                localized: "ポモジェムProが使えるようになりました。",
                table: "Paywall",
                comment: "Paywall alert after a completed purchase"
            )
        }
        return PaywallAlert(title: Constants.UIStrings.paywallTitle, message: message)
    }

    static let restored = PaywallAlert(
        title: Constants.UIStrings.paywallTitle,
        message: String(localized: "購入を復元しました。Proの機能を使えます。", table: "Paywall", comment: "Paywall alert: restore found the Pro purchase")
    )

    /// settings-05. StoreKit answered `.pending` (usually Ask to Buy). Says
    /// what happens next, and that nothing is lost by closing the screen.
    static let approvalRequested = PaywallAlert(
        title: String(localized: "承認を待っています", table: "Paywall", comment: "Paywall alert title: the purchase awaits approval (Ask to Buy)"),
        message: String(
            localized: "購入のリクエストを送りました。承認されると、自動でProが使えるようになります。この画面は閉じても大丈夫です。",
            table: "Paywall",
            comment: "Paywall alert: the purchase request was sent and Pro turns on by itself once approved"
        )
    )

    /// App Store sync finished and this Apple Account owns no Pro purchase.
    static let nothingToRestore = PaywallAlert(
        title: String(localized: "復元できる購入がありません", table: "Paywall", comment: "Paywall alert title: restore found no purchase"),
        message: String(
            localized: "このApple Accountでは、ポモジェムProの購入が見つかりませんでした。購入したときと同じApple Accountでサインインしているか確認してください。",
            table: "Paywall",
            comment: "Paywall alert: restore found no Pro purchase for the signed-in Apple Account"
        )
    )
}

/// settings-02 / a11y-07. Turns a StoreKit or purchase error into the words a
/// person can act on. StoreKit's own `localizedDescription` is framework text
/// ("The operation couldn’t be completed. (NSURLErrorDomain error -1009.)",
/// "Unable to Complete Purchase") and is never shown. A deliberate cancel —
/// closing the Apple Account prompt — is not a failure and returns nil, so
/// the paywall stays quiet.
enum PaywallErrorCopy {
    static func message(for error: Error, action: PaywallAction) -> String? {
        if let storeKitError = error as? StoreKitError {
            switch storeKitError {
            case .userCancelled:
                return nil
            case .networkError:
                return action == .loadProduct ? networkReload : network
            case .notAvailableInStorefront:
                return String(
                    localized: "お使いのApple Accountの国や地域では、この商品を購入できません。",
                    table: "Paywall",
                    comment: "Paywall error: the item is not sold in this App Store storefront"
                )
            default:
                return fallback(for: action)
            }
        }
        if let purchaseError = error as? Product.PurchaseError {
            switch purchaseError {
            case .purchaseNotAllowed:
                return String(
                    localized: "このiPhoneでは、App内での購入が制限されています。「設定」の「スクリーンタイム」から「コンテンツとプライバシーの制限」を確認してください。",
                    table: "Paywall",
                    comment: "Paywall error: In-App Purchases are turned off in Screen Time (Content & Privacy Restrictions)"
                )
            case .productUnavailable:
                return String(
                    localized: "この商品は現在購入できません。時間をおいて、もう一度お試しください。",
                    table: "Paywall",
                    comment: "Paywall error: the App Store reports the product as unavailable"
                )
            default:
                return fallback(for: action)
            }
        }
        if let managerError = error as? PurchaseManagerError {
            switch managerError {
            case .failedVerification:
                return String(
                    localized: "App Storeの購入情報を確認できませんでした。時間をおいて、もう一度お試しください。",
                    table: "Paywall",
                    comment: "Paywall error: the signed App Store transaction did not verify"
                )
            case .productUnavailable:
                // The App Store answered without this product; nothing says
                // the connection is at fault.
                return action == .loadProduct ? fallback(for: action) : managerError.errorDescription
            case .restoreInProgress:
                return managerError.errorDescription
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return action == .loadProduct ? networkReload : network
        }
        return fallback(for: action)
    }

    private static var network: String {
        String(
            localized: "App Storeに接続できませんでした。通信状態を確認して、もう一度お試しください。",
            table: "Paywall",
            comment: "Paywall error: no connection to the App Store during a purchase or restore"
        )
    }

    private static var networkReload: String {
        String(
            localized: "App Storeに接続できませんでした。通信状態を確認して、商品情報を再読み込みしてください。",
            table: "Paywall",
            comment: "Paywall error under 「商品情報を読み込めませんでした」: no connection to the App Store"
        )
    }

    /// The alert title already says what failed; this says what to do.
    private static func fallback(for action: PaywallAction) -> String {
        switch action {
        case .purchase, .restore:
            String(
                localized: "時間をおいて、もう一度お試しください。",
                table: "Paywall",
                comment: "Paywall error body under a failure title when the cause is not known"
            )
        case .loadProduct:
            String(
                localized: "時間をおいて、商品情報を再読み込みしてください。",
                table: "Paywall",
                comment: "Paywall error under 「商品情報を読み込めませんでした」 when the cause is not known"
            )
        }
    }
}
