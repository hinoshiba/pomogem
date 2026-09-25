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
        case .productUnavailable:
            return "商品情報を読み込めませんでした。通信状態を確認して、もう一度お試しください。"
        case .failedVerification:
            return "購入情報を確認できませんでした。"
        case .restoreInProgress:
            return "購入情報を復元しています。完了までお待ちください。"
        }
    }
}

enum ProTransactionDeliveryDecision: Equatable, Sendable {
    case ignoreUnknownProduct
    case rejectUnverified
    case rejectInvalidProductType
    case grant
    case reconcileWithoutGrant

    var shouldAcknowledge: Bool {
        switch self {
        case .grant, .reconcileWithoutGrant:
            true
        case .ignoreUnknownProduct, .rejectUnverified, .rejectInvalidProductType:
            false
        }
    }
}

/// Classifies transaction metadata before any entitlement mutation or StoreKit
/// acknowledgement. Unknown and unverified transactions remain unfinished so
/// this facade never consumes work owned by another product handler.
enum ProTransactionDelivery {
    static func decision(
        isVerified: Bool,
        productID: String,
        productType: Product.ProductType,
        revocationDate: Date?,
        isUpgraded: Bool
    ) -> ProTransactionDeliveryDecision {
        guard isVerified else { return .rejectUnverified }
        guard productID == IntegrationConstants.proProductID else {
            return .ignoreUnknownProduct
        }
        guard productType == .nonConsumable else {
            return .rejectInvalidProductType
        }
        guard revocationDate == nil, !isUpgraded else {
            return .reconcileWithoutGrant
        }
        return .grant
    }

    @discardableResult
    static func process(
        decision: ProTransactionDeliveryDecision,
        applyEntitlementChange: (ProTransactionDeliveryDecision) async -> Void,
        finish: () async -> Void
    ) async -> Bool {
        guard decision.shouldAcknowledge else { return false }

        await applyEntitlementChange(decision)
        await finish()
        return true
    }
}

/// Process-local arbitration for the same verified transaction arriving from
/// `purchase()`, `Transaction.unfinished`, and `Transaction.updates` together.
/// StoreKit remains the cross-launch authority: an interrupted finish is still
/// returned by `unfinished` after the next process launch.
struct ProTransactionFinishGate: Equatable, Sendable {
    private(set) var claimedTransactionIDs: Set<UInt64> = []

    mutating func claim(_ transactionID: UInt64) -> Bool {
        claimedTransactionIDs.insert(transactionID).inserted
    }
}

/// StoreKit 2 facade for the app's single non-consumable Pro purchase.
/// `Transaction.currentEntitlements` is always the authority; no mutable Pro
/// boolean is persisted locally or trusted as proof of purchase.
@MainActor
@Observable
final class PurchaseManager {
    static let shared = PurchaseManager()

    static func startAtAppLaunch() {
        _ = shared
    }

    private(set) var product: Product?
    private(set) var entitlement: ProEntitlement?
    private(set) var isLoadingProducts = false
    private(set) var isPurchasing = false
    private(set) var isRestoring = false
    private(set) var productLoadErrorDescription: String?
    private(set) var lastErrorDescription: String?
    /// Whether StoreKit has answered at least once in this process. Until it
    /// has, `isPro == false` means "not known yet", not "free": the cold pass
    /// starts at App.init but can still be running when the first screens
    /// read the entitlement. Callers whose reaction to "free" is destructive
    /// (Screen Time retiring a Pro user's learning run) must wait for this.
    /// It never goes back to false, and it never grants anything by itself.
    private(set) var hasResolvedEntitlements = false

    @ObservationIgnored
    private var transactionUpdatesTask: Task<Void, Never>?
    @ObservationIgnored
    private var coldLaunchReconciliationTask: Task<Void, Never>?
    @ObservationIgnored
    private var finishGate = ProTransactionFinishGate()
    @ObservationIgnored
    private var entitlementRefreshGeneration: UInt64 = 0

    private init() {
        // Subscribe first. The finite unfinished pass then closes the interval
        // between the prior process terminating and this listener starting.
        transactionUpdatesTask = observeTransactionUpdates()
        coldLaunchReconciliationTask = reconcileColdLaunchTransactions()
    }

    deinit {
        transactionUpdatesTask?.cancel()
        coldLaunchReconciliationTask?.cancel()
    }

    var isPro: Bool {
        entitlement != nil
    }

    func prepare() async {
        if let coldLaunchReconciliationTask {
            await coldLaunchReconciliationTask.value
        } else {
            await refreshEntitlements()
        }
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
            }), fetchedProduct.type == .nonConsumable else {
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
        guard product.id == IntegrationConstants.proProductID,
              product.type == .nonConsumable else {
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
                let decision = await processVerifiedTransaction(transaction)
                guard decision != .ignoreUnknownProduct else {
                    throw PurchaseManagerError.productUnavailable(transaction.productID)
                }
                guard decision == .grant else {
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
        entitlementRefreshGeneration &+= 1
        let generation = entitlementRefreshGeneration
        var currentEntitlement: ProEntitlement?
        var encounteredVerificationFailure = false

        for await result in Transaction.currentEntitlements {
            guard !Task.isCancelled else { return }
            guard case let .verified(transaction) = result else {
                encounteredVerificationFailure = true
                continue
            }
            let decision = ProTransactionDelivery.decision(
                isVerified: true,
                productID: transaction.productID,
                productType: transaction.productType,
                revocationDate: transaction.revocationDate,
                isUpgraded: transaction.isUpgraded
            )
            guard decision == .grant else {
                continue
            }

            currentEntitlement = .lifetime(productID: transaction.productID)
        }

        // An update delivered while this sequence was suspended has newer
        // authority and must not be overwritten by this older snapshot.
        guard generation == entitlementRefreshGeneration else { return }
        entitlement = currentEntitlement
        if !hasResolvedEntitlements { hasResolvedEntitlements = true }
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
                    await self.processVerifiedTransaction(transaction)
                case .unverified:
                    self.lastErrorDescription = PurchaseManagerError
                        .failedVerification
                        .localizedDescription
                }
            }
        }
    }

    private func reconcileColdLaunchTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            var encounteredVerificationFailure = false
            for await result in Transaction.unfinished {
                guard !Task.isCancelled else { return }
                switch result {
                case let .verified(transaction):
                    await self.processVerifiedTransaction(transaction)
                case .unverified:
                    // Never deliver or finish content whose signed payload did
                    // not verify. Leaving it unfinished permits later recovery.
                    encounteredVerificationFailure = true
                }
            }

            guard !Task.isCancelled else { return }
            await self.refreshEntitlements()
            if encounteredVerificationFailure {
                self.lastErrorDescription = PurchaseManagerError
                    .failedVerification
                    .localizedDescription
            }
        }
    }

    @discardableResult
    private func processVerifiedTransaction(
        _ transaction: Transaction
    ) async -> ProTransactionDeliveryDecision {
        let decision = ProTransactionDelivery.decision(
            isVerified: true,
            productID: transaction.productID,
            productType: transaction.productType,
            revocationDate: transaction.revocationDate,
            isUpgraded: transaction.isUpgraded
        )
        await ProTransactionDelivery.process(
            decision: decision,
            applyEntitlementChange: { [self] decision in
                switch decision {
                case .grant:
                    // Invalidate any current-entitlements pass suspended on an
                    // older snapshot before publishing this verified delivery.
                    entitlementRefreshGeneration &+= 1
                    entitlement = .lifetime(productID: transaction.productID)
                    // A verified delivery is an answer from StoreKit too.
                    if !hasResolvedEntitlements { hasResolvedEntitlements = true }
                    lastErrorDescription = nil
                case .reconcileWithoutGrant:
                    // A refund, revocation, or upgraded-away transaction must
                    // never grant Pro. Re-query in case another valid purchase
                    // still supplies the entitlement.
                    await refreshEntitlements()
                case .ignoreUnknownProduct, .rejectUnverified,
                     .rejectInvalidProductType:
                    break
                }
            },
            finish: { [self] in
                await finishIfNeeded(transaction)
            }
        )
        if decision == .rejectInvalidProductType {
            lastErrorDescription = PurchaseManagerError
                .failedVerification
                .localizedDescription
        }
        return decision
    }

    private func finishIfNeeded(_ transaction: Transaction) async {
        guard finishGate.claim(transaction.id) else { return }
        await transaction.finish()
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
