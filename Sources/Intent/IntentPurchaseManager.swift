import StoreKit

/// Owns the full StoreKit 2 purchase lifecycle — product loading, purchase,
/// cryptographic transaction verification, and revenue attribution to Intent.
///
/// IntentFlowViewController uses this automatically on paywall screens.
/// You can also call it directly for custom paywall UIs.
///
/// Usage:
///   let products = try await IntentPurchaseManager.shared.loadProducts(ids: ["com.app.pro_monthly"])
///   let result = try await IntentPurchaseManager.shared.purchase(product: product, flowId: flow.id, screenId: screen.id)
@available(iOS 15, *)
public final class IntentPurchaseManager {

    // MARK: - Singleton

    public static let shared = IntentPurchaseManager()

    private var transactionListenerTask: Task<Void, Error>?

    private init() {
        // Start listening for transactions immediately (handles renewals + interrupted purchases)
        transactionListenerTask = listenForTransactionUpdates()
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    // MARK: - Products

    /// Fetches App Store products for the given product identifiers.
    /// Returns products in the same order as `ids`. Products not found in the App Store are omitted.
    public func loadProducts(ids: [String]) async throws -> [Product] {
        guard !ids.isEmpty else { return [] }
        let fetched = try await Product.products(for: Set(ids))
        // Restore caller's order
        return ids.compactMap { id in fetched.first { $0.id == id } }
    }

    // MARK: - Purchase

    /// Initiates a purchase through StoreKit 2, verifies the transaction server-side
    /// via Apple's signed JWS payload, then reports the revenue event to Intent for
    /// flow/screen attribution.
    ///
    /// - Parameters:
    ///   - product: The StoreKit `Product` to purchase.
    ///   - flowId: The Intent flow ID shown at time of purchase (for attribution).
    ///   - screenId: The paywall screen ID (for attribution).
    /// - Returns: An `IntentPurchaseResult` describing the outcome.
    @MainActor
    public func purchase(
        product: Product,
        flowId: String,
        screenId: String?
    ) async throws -> IntentPurchaseResult {

        let purchaseResult = try await product.purchase()

        switch purchaseResult {
        case let .success(verificationResult):
            // Cryptographically verify the transaction — this is the StoreKit 2 guarantee.
            let transaction = try checkVerified(verificationResult)

            // Report to Intent for flow-level revenue attribution
            await Intent.shared.reportPurchase(
                productId: product.id,
                transactionId: String(transaction.id),
                flowId: flowId,
                screenId: screenId,
                price: NSDecimalNumber(decimal: product.price).doubleValue,
                currency: product.priceFormatStyle.locale.currency?.identifier ?? "USD"
            )

            // Keep subscriptionStatus in sync so campaigns can target active subscribers
            Intent.shared.subscriptionStatus = .active(productId: product.id)

            // Always finish verified transactions
            await transaction.finish()

            return .success(productId: product.id, transaction: transaction)

        case .userCancelled:
            return .cancelled

        case .pending:
            // Requires parental approval or SCA — do not finish, Apple will update later
            return .pending

        @unknown default:
            return .cancelled
        }
    }

    // MARK: - Entitlements

    /// Returns product IDs for all active subscriptions and non-consumable purchases.
    /// Use this on app launch to restore state without triggering an App Store prompt.
    public func currentEntitlements() async -> [String] {
        var active: [String] = []
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                active.append(transaction.productID)
            }
        }
        return active
    }

    // MARK: - Transaction update listener

    /// Handles renewals, interrupted purchases, and purchases initiated outside the app
    /// (e.g. promoted in-app purchases from the App Store, or SCA-approved pending purchases).
    private func listenForTransactionUpdates() -> Task<Void, Error> {
        Task.detached(priority: .background) {
            for await result in Transaction.updates {
                guard let transaction = try? self.checkVerified(result) else { continue }
                await MainActor.run {
                    Intent.shared.subscriptionStatus = .active(productId: transaction.productID)
                }
                await transaction.finish()
            }
        }
    }

    // MARK: - Verification

    /// Verifies a StoreKit 2 transaction. Throws if Apple's signature check fails.
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case let .unverified(_, verificationError):
            throw verificationError
        case let .verified(safe):
            return safe
        }
    }
}

// MARK: - Purchase Result

/// The outcome of a StoreKit 2 purchase attempt.
public enum IntentPurchaseResult {
    /// Purchase succeeded and was cryptographically verified.
    case success(productId: String, transaction: Transaction)
    /// User dismissed the payment sheet without purchasing.
    case cancelled
    /// Purchase requires external action (parental approval / SCA). Do not deliver content yet.
    case pending
}
