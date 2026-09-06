import Foundation
import StoreKit
import SwiftUI

enum PaywallContext {
    case settings
    case customTimer
    case aggregateLabels
}

struct PaywallView: View {
    let context: PaywallContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var purchase = PurchaseManager.shared
    @State private var purchaseMessage: String?
    @State private var didPrepare = false

    private static let purchaseHistoryURL = URL(
        string: "https://reportaproblem.apple.com/"
    )!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    hero
                    features
                    paywallContent
                    restoreButton
                    legalNote
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 34)
            }
            .background(NightBackground())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    PomoGemSheetCloseButton(
                        accessibilityIdentifier: "paywall.close"
                    ) {
                        dismiss()
                    }
                }
            }
        }
        .task { await preparePaywall() }
        .alert("ポモジェムPro", isPresented: Binding(
            get: { purchaseMessage != nil },
            set: { if !$0 { purchaseMessage = nil } }
        )) {
            Button("閉じる", role: .cancel) {
                if purchase.isPro { dismiss() }
            }
        } message: {
            Text(purchaseMessage ?? "")
        }
    }

    @ViewBuilder
    private var paywallContent: some View {
        if purchase.isPro {
            currentEntitlementCard
        } else if !didPrepare || (purchase.isLoadingProducts && purchase.product == nil) {
            loadingCatalog
        } else if let product = purchase.product {
            productCard(product)
        } else {
            emptyCatalog
        }
    }

    private var hero: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(PomoGemTheme.amber.opacity(0.10))
                    .frame(width: 112, height: 112)
                Image(systemName: "sparkles")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(PomoGemTheme.amber)
                    .shadow(color: PomoGemTheme.amber.opacity(0.45), radius: 20)
            }
            VStack(spacing: 8) {
                Text(Constants.UIStrings.paywallTitle)
                    .font(PomoGemTheme.brand(34))
                Text(contextCopy)
                    .font(.subheadline)
                    .foregroundStyle(PomoGemTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 24)
    }

    private var contextCopy: String {
        switch context {
        case .customTimer:
            "任意の集中時間を選べます。"
        case .aggregateLabels:
            "まとまり粒に、積み上げた月を刻めます。"
        case .settings:
            "集中のリズムと、残し方をもっと自由に。"
        }
    }

    private var features: some View {
        VStack(spacing: 0) {
            PaywallFeature(
                symbol: "timer",
                title: "任意の集中時間",
                detail: Constants.UIStrings.customDurationRange
            )
            Divider().overlay(PomoGemTheme.glassEdge.opacity(0.08))
            PaywallFeature(
                symbol: "circle.hexagongrid.fill",
                title: "まとまり粒の月刻印",
                detail: "積み重ねた月を残す"
            )
        }
        .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var currentEntitlementCard: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    Label("ポモジェムPro", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(PomoGemTheme.amber)
                    Spacer()
                    Text("購入済み")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.background)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(PomoGemTheme.amber, in: Capsule())
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("買い切り版")
                        .font(.title3.weight(.bold))
                    Text("Pro機能をずっと利用できます。更新や解約はありません。")
                        .font(.subheadline)
                        .foregroundStyle(PomoGemTheme.muted)
                }

                Link(destination: Self.purchaseHistoryURL) {
                    Label("Appleの購入履歴を確認", systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(PomoGemTheme.text)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 48)
                        .background(
                            PomoGemTheme.raised,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
            }
        }
    }

    private func productCard(_ product: Product) -> some View {
        PomoGemCard {
            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    Label("ポモジェムPro", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(PomoGemTheme.amber)
                    Spacer()
                    Text("買い切り")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.amber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(PomoGemTheme.amber.opacity(0.10), in: Capsule())
                }

                VStack(spacing: 5) {
                    Text(product.displayPrice)
                        .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    Text("1回だけのお支払い")
                        .font(.subheadline)
                        .foregroundStyle(PomoGemTheme.muted)
                }

                legalLink(
                    "価格・提供条件・販売者情報を確認",
                    destination: AppLinks.commercialDisclosure
                )

                Button {
                    Task { await buy(product) }
                } label: {
                    if purchase.isPurchasing {
                        HStack(spacing: 8) {
                            ProgressView().tint(PomoGemTheme.background)
                            Text("購入処理中…")
                        }
                    } else {
                        Text("\(product.displayPrice)でProを購入")
                    }
                }
                .buttonStyle(PomoGemPrimaryButtonStyle())
                .disabled(
                    purchase.isPurchasing
                        || purchase.isLoadingProducts
                        || purchase.isRestoring
                )
                .accessibilityIdentifier("paywall.purchase")

                Text("自動更新・無料トライアルはありません。")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var loadingCatalog: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(PomoGemTheme.amber)
            Text("App Storeの商品情報を確認しています…")
                .font(.subheadline)
                .foregroundStyle(PomoGemTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityElement(children: .combine)
    }

    private var emptyCatalog: some View {
        PomoGemCard {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundStyle(PomoGemTheme.amber)
                Text("商品情報を読み込めませんでした")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(
                    purchase.productLoadErrorDescription
                        ?? "通信状態を確認して、App Storeの商品情報を再読み込みしてください。"
                )
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .multilineTextAlignment(.center)
                catalogRetryButton
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var catalogRetryButton: some View {
        Button {
            Task { await reloadProduct() }
        } label: {
            if purchase.isLoadingProducts {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("再読み込み中…")
                }
            } else {
                Label("商品情報を再読み込み", systemImage: "arrow.clockwise")
            }
        }
        .buttonStyle(PomoGemSecondaryButtonStyle())
        .disabled(
            purchase.isLoadingProducts
                || purchase.isPurchasing
                || purchase.isRestoring
        )
    }

    private var restoreButton: some View {
        Button {
            Task {
                do {
                    let restored = try await purchase.restorePurchases()
                    purchaseMessage = restored
                        ? "購入を復元しました。"
                        : "購入情報の同期は完了しました。現在このApple Accountで利用できるPro購入は確認できませんでした。"
                } catch {
                    purchaseMessage = restoreFailureMessage(for: error)
                }
            }
        } label: {
            if purchase.isRestoring {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("購入情報を復元中…")
                }
            } else {
                Label("購入を復元", systemImage: "arrow.clockwise")
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(PomoGemTheme.muted)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .buttonStyle(PomoGemBareButtonStyle())
        .disabled(purchase.isRestoring || purchase.isPurchasing)
    }

    private var legalNote: some View {
        VStack(spacing: 10) {
            Text("購入はApple Accountに請求されます。ポモジェムProは1回限りの買い切りで、自動更新はありません。")
                .multilineTextAlignment(.center)
            legalLinks
        }
        .font(.caption2)
        .foregroundStyle(PomoGemTheme.muted)
    }

    @ViewBuilder
    private var legalLinks: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 0) {
                legalLink("利用規約", destination: AppLinks.standardEULA)
                legalLink("プライバシー", destination: AppLinks.privacyPolicy)
                legalLink("販売条件", destination: AppLinks.commercialDisclosure)
            }
        } else {
            HStack(spacing: 8) {
                legalLink("利用規約", destination: AppLinks.standardEULA)
                legalLink("プライバシー", destination: AppLinks.privacyPolicy)
                legalLink("販売条件", destination: AppLinks.commercialDisclosure)
            }
        }
    }

    private func legalLink(_ title: String, destination: URL) -> some View {
        Link(title, destination: destination)
            .underline()
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }

    @MainActor
    private func preparePaywall() async {
        await purchase.prepare()
        didPrepare = true
    }

    @MainActor
    private func reloadProduct() async {
        await purchase.loadProduct()
    }

    private func restoreFailureMessage(for error: Error) -> String {
        if let purchaseError = error as? PurchaseManagerError,
           purchaseError == .failedVerification {
            return "App Storeの購入情報を確認できませんでした。時間をおいて、もう一度お試しください。"
        }
        return "購入情報を復元できませんでした。通信状態を確認して、もう一度お試しください。\n\(error.localizedDescription)"
    }

    @MainActor
    private func buy(_ product: Product) async {
        do {
            let outcome = try await purchase.purchase(product)
            switch outcome {
            case .purchased:
                purchaseMessage = "ポモジェムProを利用できます。"
            case .pending:
                purchaseMessage = "購入の承認を待っています。"
            case .cancelled:
                break
            }
        } catch {
            purchaseMessage = error.localizedDescription
        }
    }
}

private struct PaywallFeature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .foregroundStyle(PomoGemTheme.amber)
                .frame(width: 26)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
    }
}
