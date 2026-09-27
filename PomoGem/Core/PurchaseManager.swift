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

/// What 「購入を復元」 found. A cancelled Apple Account prompt is the user's
/// own choice, not a failure, so it is an outcome rather than an error.
enum PurchaseRestoreOutcome: Equatable, Sendable {
    case restored
    case nothingFound
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

/// settings-05. The only trace of a purchase StoreKit answered with
/// `.pending` (Ask to Buy, or a payment that needs another step). StoreKit
/// sends nothing when a request is declined or expires (Ask to Buy requests
/// lapse after about a day), so the hint expires by itself after 24 hours
/// and is never evidence of anything: it only lets the paywall say 承認待ち
/// and lets the app say so when Pro then arrives. No entitlement path, no
/// `canUseFocusDuration` and no button state reads it.
struct ProApprovalWaitHint: Equatable, Sendable {
    static let lifetime: TimeInterval = 24 * 60 * 60
    static let defaultsKey = "pomogem.pro.approval-requested-at"

    private(set) var requestedAt: Date?

    init(requestedAt: Date? = nil) {
        self.requestedAt = requestedAt
    }

    /// A clock set back before the request reads as expired rather than as
    /// a wait that could last forever.
    func isWaiting(at now: Date) -> Bool {
        guard let requestedAt else { return false }
        let elapsed = now.timeIntervalSince(requestedAt)
        return elapsed >= 0 && elapsed < Self.lifetime
    }

    mutating func recordRequest(at now: Date) {
        requestedAt = now
    }

    /// Pro arrived. True when it answers a wait that was still open, which is
    /// the one case worth telling the user about.
    mutating func resolveGrant(at now: Date) -> Bool {
        let answersWait = isWaiting(at: now)
        requestedAt = nil
        return answersWait
    }

    /// Stored as seconds since 1970 so a UI test can seed it from the
    /// argument domain. An expired value is dropped when read.
    static func load(from defaults: UserDefaults, now: Date = .now) -> ProApprovalWaitHint {
        let seconds = defaults.double(forKey: defaultsKey)
        guard seconds > 0 else { return ProApprovalWaitHint() }
        let hint = ProApprovalWaitHint(requestedAt: Date(timeIntervalSince1970: seconds))
        return hint.isWaiting(at: now) ? hint : ProApprovalWaitHint()
    }

    func save(to defaults: UserDefaults) {
        if let requestedAt {
            defaults.set(requestedAt.timeIntervalSince1970, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }
}

/// settings-05. Where PurchaseManager saw a verified Pro grant. Every call
/// site names its path, so which grants may announce an answered approval is
/// decided here, in one tested place, rather than by a Bool at each call.
enum ProGrantPath: Equatable, Sendable, CaseIterable {
    /// `product.purchase()` returned `.success`; the paywall's own alert
    /// thanks the person in place.
    case purchase
    /// 「購入を復元」 on the paywall, which says 購入を復元しました itself.
    case restore
    /// `Transaction.updates`: an Ask to Buy approval normally arrives here.
    case transactionUpdate
    /// `Transaction.unfinished` at launch: approved while the app was closed.
    case launchReconciliation
    /// The launch, foreground and Settings passes over current entitlements.
    case entitlementRefresh

    /// Only a grant nothing on screen asked for is announced; the paywall
    /// already speaks for its own purchase and restore.
    var announcesAnsweredWait: Bool {
        switch self {
        case .purchase, .restore:
            false
        case .transactionUpdate, .launchReconciliation, .entitlementRefresh:
            true
        }
    }
}

/// settings-05. The approval-wait bookkeeping PurchaseManager keeps, as a
/// value: the display-only hint, and the one notice owed when a grant answers
/// an open wait. StoreKit's `.pending` and approved transactions cannot be
/// produced by a unit test (and SKTestSession is refused from the command
/// line on this project's iOS 26.5 Simulator, Docs/ProTimerPrecision.md), so
/// PurchaseManager routes every step through this type and the tests drive
/// the same steps. Nothing here reads or changes the entitlement.
struct ProApprovalWaitState: Equatable, Sendable {
    private(set) var hint: ProApprovalWaitHint
    /// Owed until a toast can actually be seen (see `consumeGrantNotice`).
    private(set) var hasGrantNotice = false

    init(hint: ProApprovalWaitHint = ProApprovalWaitHint()) {
        self.hint = hint
    }

    /// Display only: never gates a purchase, a button or a feature.
    func isAwaitingApproval(isPro: Bool, at now: Date) -> Bool {
        !isPro && hint.isWaiting(at: now)
    }

    /// StoreKit answered a purchase with `.pending`.
    mutating func recordPendingRequest(at now: Date) {
        hint.recordRequest(at: now)
    }

    /// Pro was granted. Ends the wait either way; owes a notice only when
    /// the grant answers a wait that was still open and came from a path
    /// that did not already tell the person.
    mutating func proGranted(via path: ProGrantPath, at now: Date) {
        let answeredWait = hint.resolveGrant(at: now)
        if answeredWait, path.announcesAnsweredWait { hasGrantNotice = true }
    }

    /// Hands out the notice once, and only when it can be seen. The toast is
    /// drawn beneath every sheet and full-screen cover, so a notice taken
    /// while the focus timer or the paywall is up would be lost for good.
    mutating func consumeGrantNotice(whenVisible toastIsVisible: Bool) -> Bool {
        guard hasGrantNotice, toastIsVisible else { return false }
        hasGrantNotice = false
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
    /// settings-05. Display-only; see `ProApprovalWaitState`.
    private(set) var approvalWait = ProApprovalWaitState(hint: .load(from: .standard))

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

    /// A purchase asked for approval within the last day and Pro has not
    /// arrived. Never gates anything: the buy button stays available, since a
    /// declined or expired request sends no signal at all.
    func isAwaitingApproval(at now: Date = .now) -> Bool {
        approvalWait.isAwaitingApproval(isPro: isPro, at: now)
    }

    /// Pro arrived for a request that was waiting for approval, and nothing
    /// on screen has said so yet.
    var hasApprovalGrantNotice: Bool {
        approvalWait.hasGrantNotice
    }

    /// True once per approval that arrived while the app was waiting for it,
    /// and only when the caller's toast can be seen right now.
    func consumeApprovalGrantNotice(whenVisible toastIsVisible: Bool) -> Bool {
        var consumed = false
        updateApprovalWait { consumed = $0.consumeGrantNotice(whenVisible: toastIsVisible) }
        return consumed
    }

#if DEBUG && targetEnvironment(simulator)
    /// ApprovalArrivalUITestFixture only. The bookkeeping an Ask to Buy
    /// approval arriving through `Transaction.updates` performs, without the
    /// entitlement: StoreKit cannot approve anything in the Simulator run.
    func recordApprovalArrivalForUITest(at now: Date = .now) {
        updateApprovalWait {
            $0.recordPendingRequest(at: now)
            $0.proGranted(via: .transactionUpdate, at: now)
        }
    }
#endif

    private func updateApprovalWait(_ change: (inout ProApprovalWaitState) -> Void) {
        var state = approvalWait
        change(&state)
        guard state != approvalWait else { return }
        let hintChanged = state.hint != approvalWait.hint
        approvalWait = state
        if hintChanged { state.hint.save(to: .standard) }
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
                productLoadErrorDescription = PaywallErrorCopy.message(for: error, action: .loadProduct)
                lastErrorDescription = error.localizedDescription
                return
            }

            product = fetchedProduct
            productLoadErrorDescription = nil
            lastErrorDescription = nil
        } catch {
            product = nil
            // Shown under 「商品情報を読み込めませんでした」: never StoreKit's
            // own framework text (settings-02).
            productLoadErrorDescription = PaywallErrorCopy.message(for: error, action: .loadProduct)
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
                let decision = await processVerifiedTransaction(
                    transaction,
                    grantPath: .purchase
                )
                guard decision != .ignoreUnknownProduct else {
                    throw PurchaseManagerError.productUnavailable(transaction.productID)
                }
                guard decision == .grant else {
                    throw PurchaseManagerError.failedVerification
                }
                return .purchased

            case .pending:
                lastErrorDescription = nil
                updateApprovalWait { $0.recordPendingRequest(at: .now) }
                return .pending

            case .userCancelled:
                lastErrorDescription = nil
                return .cancelled

            @unknown default:
                lastErrorDescription = nil
                updateApprovalWait { $0.recordPendingRequest(at: .now) }
                return .pending
            }
        } catch StoreKitError.userCancelled {
            // Some flows throw the cancel instead of returning it.
            lastErrorDescription = nil
            return .cancelled
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    /// Calls App Store sync only in response to the explicit "購入を復元" action.
    @discardableResult
    func restorePurchases() async throws -> PurchaseRestoreOutcome {
        guard !isRestoring else {
            throw PurchaseManagerError.restoreInProgress
        }
        isRestoring = true
        defer { isRestoring = false }

        do {
            try await AppStore.sync()
            // The paywall says 購入を復元しました itself, so a restore that
            // answers an open approval wait owes no second notice.
            await refreshEntitlements(grantPath: .restore)
            if !isPro,
               lastErrorDescription == PurchaseManagerError.failedVerification.localizedDescription {
                throw PurchaseManagerError.failedVerification
            }
            lastErrorDescription = nil
            return isPro ? .restored : .nothingFound
        } catch StoreKitError.userCancelled {
            // settings-02. `AppStore.sync()` throws this when the person
            // closes the Apple Account prompt. They chose not to sign in;
            // nothing failed, so nothing is reported.
            lastErrorDescription = nil
            return .cancelled
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func refreshEntitlements() async {
        await refreshEntitlements(grantPath: .entitlementRefresh)
    }

    private func refreshEntitlements(grantPath: ProGrantPath) async {
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
        // An approval can also surface here first (a restore, or a cold
        // launch after StoreKit finished it elsewhere).
        if currentEntitlement != nil {
            updateApprovalWait { $0.proGranted(via: grantPath, at: .now) }
        }
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
                    await self.processVerifiedTransaction(
                        transaction,
                        grantPath: .transactionUpdate
                    )
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
                    await self.processVerifiedTransaction(
                        transaction,
                        grantPath: .launchReconciliation
                    )
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
        _ transaction: Transaction,
        grantPath: ProGrantPath
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
                    updateApprovalWait { $0.proGranted(via: grantPath, at: .now) }
                case .reconcileWithoutGrant:
                    // A refund, revocation, or upgraded-away transaction must
                    // never grant Pro. Re-query in case another valid purchase
                    // still supplies the entitlement.
                    await refreshEntitlements(grantPath: grantPath)
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
