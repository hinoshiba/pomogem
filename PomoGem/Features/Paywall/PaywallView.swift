import Foundation
import StoreKit
import SwiftUI

enum PaywallContext {
    case settings
    case customTimer
    case aggregateLabels
    case screenTimeApps
}

struct PaywallView: View {
    let context: PaywallContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var purchase = PurchaseManager.shared
    @State private var alert: PaywallAlert?
    @State private var didPrepare = false

    private static let purchaseHistoryURL = URL(
        string: "https://reportaproblem.apple.com/"
    )!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
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
        .alert(alert?.title ?? "", isPresented: Binding(
            get: { alert != nil },
            set: { if !$0 { alert = nil } }
        ), presenting: alert) { _ in
            Button(String(localized: "閉じる", table: "Paywall", comment: "Paywall alert button: close the alert"), role: .cancel) {
                if purchase.isPro { dismiss() }
            }
        } message: { alert in
            Text(alert.message)
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

    /// settings-04. Small enough that on a 5.4" iPhone the features and the
    /// price start above the fold; at accessibility sizes the decorative
    /// circle gives its room to the words.
    private var hero: some View {
        VStack(spacing: 14) {
            if !dynamicTypeSize.isAccessibilitySize {
                ZStack {
                    Circle()
                        .fill(PomoGemTheme.amber.opacity(0.10))
                        .frame(width: 72, height: 72)
                    Image(systemName: "sparkles")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(PomoGemTheme.amber)
                        .shadow(color: PomoGemTheme.amber.opacity(0.45), radius: 14)
                }
                .accessibilityHidden(true)
            }
            VStack(spacing: 8) {
                Text(Constants.UIStrings.paywallTitle)
                    .font(PomoGemTheme.brand(34))
                    // Shrink the product name instead of breaking it
                    // mid-word (「ポモジェ／ムPro」) at the largest sizes.
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(contextCopy)
                    .font(.subheadline)
                    .foregroundStyle(PomoGemTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 12)
    }

    private var contextCopy: String {
        switch context {
        case .customTimer:
            // The same noun as the first feature row and Settings' Pro row.
            String(localized: "自由な集中時間を選べます。", table: "Paywall", comment: "Paywall subtitle when opened from the custom focus duration control")
        case .aggregateLabels:
            String(localized: "結晶に、作った月を刻めます。", table: "Paywall", comment: "Paywall subtitle when opened from the crystal month-label hint")
        case .screenTimeApps:
            String(localized: "勉強時間を記録するアプリを、数の制限なく選べます。", table: "Paywall",
                   comment: "Paywall subtitle when opened from Screen Time's study-app limit")
        case .settings:
            String(localized: "集中のリズムと、残し方をもっと自由に。", table: "Paywall",
                   comment: "Paywall subtitle when opened from Settings: more freedom in how you focus and keep your record")
        }
    }

    /// settings-04. The feature the person came for comes first and is
    /// marked; each row says what stays free next to what Pro adds; and
    /// one line says everything else is free. Nothing here is a timer, a
    /// countdown or a comparison designed to make the free plan look bad.
    private var features: some View {
        let kinds = PaywallFeatureKind.ordered(for: context)
        return VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                    if index > 0 {
                        Divider().overlay(PomoGemTheme.glassEdge.opacity(0.08))
                    }
                    PaywallFeature(
                        kind: kind,
                        isHighlighted: index == 0 && PaywallFeatureKind.highlights(context),
                        monthLabelExample: DateText.yearMonth(.now)
                    )
                }
            }
            .background(PomoGemTheme.card, in: RoundedRectangle(cornerRadius: 18))

            if !purchase.isPro {
                Text(
                    "記録・テーマ・iCloud同期・シェアなど、ほかの機能はすべて無料で使えます。",
                    tableName: "Paywall",
                    comment: "Paywall note under the Pro features: everything else stays free"
                )
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("paywall.free-note")
            }
        }
    }

    private var currentEntitlementCard: some View {
        PomoGemCard {
            VStack(alignment: .leading, spacing: 16) {
                cardHeader(symbol: "checkmark.seal.fill", alignment: .center) {
                    Text("購入済み", tableName: "Paywall", comment: "Paywall badge: Pro is already purchased")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.background)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(PomoGemTheme.amber, in: Capsule())
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("買い切り版", tableName: "Paywall", comment: "Paywall, Pro owned: the one-time purchase edition")
                        .font(.title3.weight(.bold))
                    Text("Pro機能をずっと利用できます。更新や解約はありません。", tableName: "Paywall",
                         comment: "Paywall, Pro owned: Pro features stay available; nothing to renew or cancel")
                        .font(.subheadline)
                        .foregroundStyle(PomoGemTheme.muted)
                }

                Link(destination: Self.purchaseHistoryURL) {
                    Label {
                        Text("Appleの購入履歴を確認", tableName: "Paywall",
                             comment: "Paywall, Pro owned: link to Apple's purchase history on reportaproblem.apple.com")
                    } icon: {
                        Image(systemName: "arrow.up.right.square")
                    }
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
                cardHeader(symbol: "sparkles") {
                    Text("買い切り", tableName: "Paywall", comment: "Paywall badge: one-time purchase (no subscription)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PomoGemTheme.amber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(PomoGemTheme.amber.opacity(0.10), in: Capsule())
                }

                VStack(spacing: 5) {
                    Text(product.displayPrice)
                        .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                    Text("1回だけのお支払い", tableName: "Paywall", comment: "Paywall: under the price, you pay once")
                        .font(.subheadline)
                        .foregroundStyle(PomoGemTheme.muted)
                }

                legalLink(
                    String(localized: "価格・提供条件・販売者情報を確認", table: "Paywall",
                           comment: "Paywall link: price, terms of sale and seller information (commercial disclosure page)"),
                    destination: AppLinks.commercialDisclosure
                )

                if purchase.isAwaitingApproval() {
                    approvalPendingNotice
                    // settings-05. Never disabled: a declined or expired
                    // request sends no signal, so asking again must stay
                    // possible. It is the quieter button while a request is
                    // out, so it does not read as "buy again".
                    purchaseButton(product, spinnerTint: PomoGemTheme.text) {
                        Text("もう一度リクエスト", tableName: "Paywall", comment: "Paywall button while a purchase awaits approval: ask again")
                    }
                    .buttonStyle(PomoGemSecondaryButtonStyle())
                } else {
                    purchaseButton(product, spinnerTint: PomoGemTheme.background) {
                        Text("\(product.displayPrice)でProを購入", tableName: "Paywall",
                             comment: "Paywall buy button; %@ is the App Store price, e.g. ¥480")
                    }
                    .buttonStyle(PomoGemPrimaryButtonStyle())
                }

                Text("自動更新・無料トライアルはありません。", tableName: "Paywall",
                     comment: "Paywall: no auto-renewal and no free trial")
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// The product name and a badge on one line, as before; stacked when
    /// they do not fit on one line. At accessibility sizes the row broke
    /// both words letter by letter (「ポモジェ／ムPro」, "Po/mo/Ge/m"), and the
    /// English badge "One-Time Purchase" is far wider than 「買い切り」.
    private func cardHeader<Badge: View>(
        symbol: String,
        alignment: VerticalAlignment = .center,
        @ViewBuilder badge: () -> Badge
    ) -> some View {
        let name = Label {
            Text("ポモジェムPro", tableName: "Paywall", comment: "Paywall card title: the product name, on the buy card and once Pro is owned")
        } icon: {
            Image(systemName: symbol)
                .accessibilityHidden(true)
        }
            .font(.headline)
            .foregroundStyle(PomoGemTheme.amber)
        let badge = badge()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: alignment, spacing: 12) {
                name
                Spacer()
                badge
            }
            VStack(alignment: .leading, spacing: 8) {
                name
                badge
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// `spinnerTint` follows the button's style: the dark background on the
    /// amber primary button, the text colour on the dark secondary one.
    private func purchaseButton<Label: View>(
        _ product: Product,
        spinnerTint: Color,
        @ViewBuilder label: () -> Label
    ) -> some View {
        let idleLabel = label()
        return Button {
            Task { await buy(product) }
        } label: {
            if purchase.isPurchasing {
                HStack(spacing: 8) {
                    ProgressView().tint(spinnerTint)
                    Text("購入処理中…", tableName: "Paywall", comment: "Paywall buy button while the purchase is in progress")
                }
            } else {
                idleLabel
            }
        }
        .disabled(
            purchase.isPurchasing
                || purchase.isLoadingProducts
                || purchase.isRestoring
        )
        .accessibilityIdentifier("paywall.purchase")
    }

    /// settings-05. What a pending purchase looks like after its alert is
    /// gone: without it the paywall looked exactly as before the request.
    private var approvalPendingNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hourglass")
                .font(.title3)
                .foregroundStyle(PomoGemTheme.amber)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("承認待ち", tableName: "Paywall", comment: "Paywall notice title: a purchase request awaits approval")
                    .font(.subheadline.weight(.bold))
                Text(
                    "承認されると、自動でProが使えるようになります。届かないときは、もう一度リクエストできます。",
                    tableName: "Paywall",
                    comment: "Paywall notice under 承認待ち: what happens next"
                )
                .font(.caption)
                .foregroundStyle(PomoGemTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(PomoGemTheme.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paywall.approval-pending")
    }

    private var loadingCatalog: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(PomoGemTheme.amber)
            Text("App Storeの商品情報を確認しています…", tableName: "Paywall",
                 comment: "Paywall: loading the product from the App Store")
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
                Text("商品情報を読み込めませんでした", tableName: "Paywall",
                     comment: "Paywall: the product could not be loaded from the App Store")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(
                    purchase.productLoadErrorDescription
                        ?? String(localized: "通信状態を確認して、App Storeの商品情報を再読み込みしてください。", table: "Paywall",
                                  comment: "Paywall, under 商品情報を読み込めませんでした: check the connection and reload")
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
                    Text("再読み込み中…", tableName: "Paywall", comment: "Paywall: reloading the product")
                }
            } else {
                Label {
                    Text("商品情報を再読み込み", tableName: "Paywall", comment: "Paywall button: reload the product from the App Store")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
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
                    switch try await purchase.restorePurchases() {
                    case .restored:
                        alert = .restored
                    case .nothingFound:
                        alert = .nothingToRestore
                    case .cancelled:
                        break
                    }
                } catch {
                    if let message = PaywallErrorCopy.message(for: error, action: .restore) {
                        alert = .failure(.restore, message: message)
                    }
                }
            }
        } label: {
            if purchase.isRestoring {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("購入情報を復元中…", tableName: "Paywall", comment: "Paywall: restoring purchases in progress")
                }
            } else {
                Label {
                    Text("購入を復元", tableName: "Paywall", comment: "Paywall button: Restore Purchases")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                }
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
            Text("購入はApple Accountに請求されます。ポモジェムProは1回限りの買い切りで、自動更新はありません。", tableName: "Paywall",
                 comment: "Paywall legal note: charged to the Apple Account; a one-time purchase that never auto-renews")
                .multilineTextAlignment(.center)
            legalLinks
        }
        .font(.caption2)
        .foregroundStyle(PomoGemTheme.muted)
    }

    @ViewBuilder
    private var legalLinks: some View {
        let terms = String(localized: "利用規約", table: "Paywall", comment: "Paywall legal link: Apple's standard EULA (Terms of Use)")
        let privacy = String(localized: "プライバシー", table: "Paywall", comment: "Paywall legal link: the privacy policy")
        let sale = String(localized: "販売条件", table: "Paywall", comment: "Paywall legal link: Terms of Sale (commercial disclosure)")
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 0) {
                legalLink(terms, destination: AppLinks.standardEULA)
                legalLink(privacy, destination: AppLinks.privacyPolicy)
                legalLink(sale, destination: AppLinks.commercialDisclosure)
            }
        } else {
            HStack(spacing: 8) {
                legalLink(terms, destination: AppLinks.standardEULA)
                legalLink(privacy, destination: AppLinks.privacyPolicy)
                legalLink(sale, destination: AppLinks.commercialDisclosure)
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

    @MainActor
    private func buy(_ product: Product) async {
        do {
            let outcome = try await purchase.purchase(product)
            switch outcome {
            case .purchased:
                alert = .purchased(context: context)
            case .pending:
                alert = .approvalRequested
            case .cancelled:
                break
            }
        } catch {
            if let message = PaywallErrorCopy.message(for: error, action: .purchase) {
                alert = .failure(.purchase, message: message)
            }
        }
    }
}

/// settings-04. The three things Pro adds, in one place so the paywall can
/// put the one that matches its entry point first.
enum PaywallFeatureKind: CaseIterable, Hashable {
    case customDuration
    case monthLabel
    case studyApps

    /// The entry point's feature first; the rest keep their usual order.
    static func ordered(for context: PaywallContext) -> [PaywallFeatureKind] {
        let first: PaywallFeatureKind? = switch context {
        case .customTimer: .customDuration
        case .aggregateLabels: .monthLabel
        case .screenTimeApps: .studyApps
        case .settings: nil
        }
        guard let first else { return allCases }
        return [first] + allCases.filter { $0 != first }
    }

    /// Opened from a feature (not from Settings' general Pro row).
    static func highlights(_ context: PaywallContext) -> Bool {
        context != .settings
    }

    var symbol: String {
        switch self {
        case .customDuration: "timer"
        case .monthLabel: "calendar"
        case .studyApps: "apps.iphone"
        }
    }

    var title: String {
        switch self {
        case .customDuration:
            String(localized: "自由な集中時間", table: "Paywall", comment: "Paywall feature title: any focus length")
        case .monthLabel:
            String(localized: "結晶に月を刻む", table: "Paywall", comment: "Paywall feature title: crystals show the month they were made")
        case .studyApps:
            String(localized: "勉強アプリ数が無制限", table: "Paywall", comment: "Paywall feature title: unlimited Screen Time study apps")
        }
    }

    /// What stays free is said next to what Pro adds, so nobody reads the
    /// paywall as the free timers going away.
    var detail: String {
        switch self {
        case .customDuration:
            String(
                localized: "無料の25・45・60・90分のほか、\(Constants.UIStrings.customDurationRange)を秒単位で選べます",
                table: "Paywall",
                comment: "Paywall feature detail; the argument is the Pro range, e.g. 1〜360分"
            )
        case .monthLabel:
            String(
                localized: "粒が10個集まってできる結晶に、作った月を刻みます",
                table: "Paywall",
                comment: "Paywall feature detail: what the month label is"
            )
        case .studyApps:
            String(
                localized: "スクリーンタイムで記録する勉強アプリ。無料は5つまで",
                table: "Paywall",
                comment: "Paywall feature detail: the free plan records up to five study apps"
            )
        }
    }
}

private struct PaywallFeature: View {
    let kind: PaywallFeatureKind
    let isHighlighted: Bool
    /// The current month, as a Pro crystal shows it (「2026年9月」).
    let monthLabelExample: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: kind.symbol)
                .foregroundStyle(PomoGemTheme.amber)
                .frame(width: 26)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title)
                    .font(.subheadline.weight(.semibold))
                Text(kind.detail)
                    .font(.caption)
                    .foregroundStyle(PomoGemTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if kind == .monthLabel {
                    monthLabelPreview
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 58)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 18)
                    .fill(PomoGemTheme.amber.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(PomoGemTheme.amber.opacity(0.45), lineWidth: 1)
                    }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("paywall.feature.\(kind)")
    }

    /// A static example of the month a crystal carries, not a rendering of
    /// the jar: the gem art belongs to the jar itself.
    private var monthLabelPreview: some View {
        HStack(spacing: 6) {
            Image(systemName: "diamond.fill")
                .font(.caption2)
                .foregroundStyle(PomoGemTheme.amber)
            Text(verbatim: monthLabelExample)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .monospacedDigit()
                // "September 2026" is wider than 「2026年9月」: at accessibility
                // sizes it shrinks instead of breaking the month in two.
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(PomoGemTheme.amber.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(PomoGemTheme.amber.opacity(0.35), lineWidth: 0.7))
        .accessibilityLabel(Text(
            "表示の例：\(monthLabelExample)",
            tableName: "Paywall",
            comment: "VoiceOver: an example month label; the argument is a month such as 2026年9月"
        ))
    }
}
