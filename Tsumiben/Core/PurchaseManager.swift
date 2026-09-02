import Foundation
import Observation
import StoreKit

enum ProEntitlement: Equatable, Sendable {
    case lifetime(productID: String)

    var productID: String {
        switch self {
        case let .lifetime(productID):
            return productID
        }
    }
}

enum PurchaseOutcome: Equatable, Sendable {
    case purchased
    case pending
    case cancelled
}

enum PurchaseManagerError: LocalizedError, Equatable {
    case productUnavailable(String)
    case failedVerification
    case restoreInProgress

    var errorDescription: String? {
        switch self {
        case let .productUnavailable(productID):
            return "商品情報を読み込めませんでした（\(productID)）。"
        case .failedVerification:
            return "購入情報を確認できませんでした。"
        case .restoreInProgress:
            return "購入情報を復元しています。完了までお待ちください。"
        }
    }
}

/// Applies a verified transaction before acknowledging it to StoreKit.
/// Unknown product identifiers stay unfinished so the owning product handler
/// can process them instead of this single-product facade consuming them.
enum ProTransactionDelivery {
    @discardableResult
    static func process(
        productID: String,
        applyEntitlementChange: () async -> Void,
        finish: () async -> Void
    ) async -> Bool {
        guard productID == IntegrationConstants.proProductID else {
            return false
        }

        await applyEntitlementChange()
        await finish()
        return true
    }
}

/// StoreKit 2 facade for the app's single non-consumable Pro purchase.
/// `Transaction.currentEntitlements` is always the authority; no mutable Pro
/// boolean is persisted locally or trusted as proof of purchase.
@MainActor
@Observable
final class PurchaseManager {
    static let shared = PurchaseManager()

    private(set) var product: Product?
    private(set) var entitlement: ProEntitlement?
    private(set) var isLoadingProducts = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    private(set) var productLoadErrorDescription: String?
    private(set) var lastErrorDescription: String?

    @ObservationIgnored
    private var transactionUpdatesTask: Task<Void, Never>?

    private init() {
        transactionUpdatesTask = observeTransactionUpdates()
    }

    deinit {
        transactionUpdatesTask?.cancel()
    }

    var isPro: Bool {
        entitlement != nil
    }

    func prepare() async {
        await refreshEntitlements()
        guard !isPro else { return }
        await loadProduct()
    }

    func loadProduct() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let fetchedProducts = try await Product.products(
                for: IntegrationConstants.proProductIDs
            )
            guard let fetchedProduct = fetchedProducts.first(where: {
                $0.id == IntegrationConstants.proProductID
            }) else {
                let error = PurchaseManagerError.productUnavailable(
                    IntegrationConstants.proProductID
                )
                product = nil
                productLoadErrorDescription = error.localizedDescription
                lastErrorDescription = error.localizedDescription
                return
            }

            product = fetchedProduct
            productLoadErrorDescription = nil
            lastErrorDescription = nil
        } catch {
            product = nil
            productLoadErrorDescription = error.localizedDescription
            lastErrorDescription = error.localizedDescription
        }
    }

    func purchase(productID: String) async throws -> PurchaseOutcome {
        guard productID == IntegrationConstants.proProductID else {
            let error = PurchaseManagerError.productUnavailable(productID)
            lastErrorDescription = error.localizedDescription
            throw error
        }

        if product == nil {
            await loadProduct()
        }
        guard let product, product.id == productID else {
            let error = PurchaseManagerError.productUnavailable(productID)
            lastErrorDescription = error.localizedDescription
            throw error
        }
        return try await purchase(product)
    }

    func purchase(_ product: Product) async throws -> PurchaseOutcome {
        guard product.id == IntegrationConstants.proProductID else {
            let error = PurchaseManagerError.productUnavailable(product.id)
            lastErrorDescription = error.localizedDescription
            throw error
        }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case let .success(verification):
                let transaction = try verified(verification)
                let grantsPro = transaction.revocationDate == nil
                    && !transaction.isUpgraded
                let processed = await ProTransactionDelivery.process(
                    productID: transaction.productID,
                    applyEntitlementChange: { [self] in
                        if grantsPro {
                            entitlement = .lifetime(productID: transaction.productID)
                            lastErrorDescription = nil
                        } else {
                            await refreshEntitlements()
                        }
                    },
                    finish: {
                        await transaction.finish()
                    }
                )

                guard processed else {
                    throw PurchaseManagerError.productUnavailable(transaction.productID)
                }
                guard grantsPro else {
                    throw PurchaseManagerError.failedVerification
                }
                return .purchased

            case .pending:
                lastErrorDescription = nil
                return .pending

            case .userCancelled:
                lastErrorDescription = nil
                return .cancelled

            @unknown default:
                lastErrorDescription = nil
                return .pending
            }
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    /// Calls App Store sync only in response to the explicit "購入を復元" action.
    @discardableResult
    func restorePurchases() async throws -> Bool {
        guard !isRestoring else {
            throw PurchaseManagerError.restoreInProgress
        }
        isRestoring = true
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if !isPro,
               lastErrorDescription == PurchaseManagerError.failedVerification.localizedDescription {
                throw PurchaseManagerError.failedVerification
            }
            lastErrorDescription = nil
            return isPro
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func refreshEntitlements() async {
        var currentEntitlement: ProEntitlement?
        var encounteredVerificationFailure = false

        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else {
                encounteredVerificationFailure = true
                continue
            }
            guard transaction.productID == IntegrationConstants.proProductID,
                  transaction.revocationDate == nil,
                  !transaction.isUpgraded else {
                continue
            }

            currentEntitlement = .lifetime(productID: transaction.productID)
        }

        entitlement = currentEntitlement
        lastErrorDescription = encounteredVerificationFailure
            ? PurchaseManagerError.failedVerification.localizedDescription
            : nil
    }

    func canUseFocusDuration(_ seconds: Int) -> Bool {
        IntegrationConstants.isFreeFocusDuration(seconds) || isPro
    }

    private func observeTransactionUpdates() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                guard let self else { return }

                switch result {
                case let .verified(transaction):
                    let grantsPro = transaction.revocationDate == nil
                        && !transaction.isUpgraded
                    await ProTransactionDelivery.process(
                        productID: transaction.productID,
                        applyEntitlementChange: { [self] in
                            if grantsPro {
                                entitlement = .lifetime(productID: transaction.productID)
                                lastErrorDescription = nil
                            } else {
                                await refreshEntitlements()
                            }
                        },
                        finish: {
                            await transaction.finish()
                        }
                    )
                case .unverified:
                    self.lastErrorDescription = PurchaseManagerError
                        .failedVerification
                        .localizedDescription
                }
            }
        }
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case let .verified(value):
            return value
        case .unverified:
            throw PurchaseManagerError.failedVerification
        }
    }
}
