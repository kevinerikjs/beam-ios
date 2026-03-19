// StoreManager.swift
// StoreKit 2 IAP for the one-time Beam Unlimited unlock.

import StoreKit
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "StoreManager")
private let kInfoPlistProductIDsKey = "BeamIAPProductIDs"
private let kFallbackProductIDs = [
    "com.beamapp.ios.unlimited",
    "com.beam.ios.unlimited"
]

@Observable
final class StoreManager {

    static let shared = StoreManager()

    // MARK: - State

    private(set) var isPurchased: Bool = false
    private(set) var product: Product? = nil
    private(set) var activeProductID: String? = nil
    private(set) var isPurchasing: Bool = false
    private(set) var purchaseError: String? = nil

    @ObservationIgnored
    private var transactionListener: Task<Void, Never>?

    // MARK: - Init

    private init() {
        // Listen for transaction updates (e.g., from another device)
        transactionListener = Task.detached(priority: .utility) {
            for await result in Transaction.updates {
                await self.handleTransactionResult(result)
            }
        }

        // Prime store state at app startup.
        Task {
            await refreshStoreState()
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Load Products

    func refreshStoreState() async {
        await loadProduct()
        await loadPurchaseState()
    }

    func loadProduct() async {
        let productIDs = configuredProductIDs
        guard !productIDs.isEmpty else {
            await MainActor.run {
                product = nil
                activeProductID = nil
                purchaseError = "No in-app product IDs are configured."
            }
            return
        }

        do {
            let products = try await Product.products(for: productIDs)
            let selected = productIDs.compactMap { id in
                products.first(where: { $0.id == id })
            }.first

            await MainActor.run {
                product = selected
                activeProductID = selected?.id
                if selected != nil {
                    purchaseError = nil
                } else {
                    purchaseError = "Beam Unlimited is not available yet."
                }
            }

            logger.info("Loaded \(products.count) product(s)")
        } catch {
            await MainActor.run {
                product = nil
                activeProductID = nil
                purchaseError = "Couldn't load pricing. Please try again."
            }
            logger.error("Failed to load products: \(error.localizedDescription)")
        }
    }

    // MARK: - Purchase

    @MainActor
    func purchase() async {
        if product == nil {
            await loadProduct()
        }

        guard let product else {
            purchaseError = "Product not available. Check your internet connection."
            return
        }

        isPurchasing = true
        purchaseError = nil
        Analytics.iapInitiated()

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handleTransactionResult(verification)
                await loadPurchaseState()
            case .userCancelled:
                break
            case .pending:
                // Transaction is pending (e.g., Ask to Buy)
                purchaseError = "Purchase is pending approval."
                logger.info("Purchase pending")
            @unknown default:
                purchaseError = "Purchase could not be completed."
                break
            }
        } catch {
            purchaseError = error.localizedDescription
            logger.error("Purchase failed: \(error)")
        }

        isPurchasing = false
    }

    // MARK: - Restore

    @MainActor
    func restore() async {
        isPurchasing = true
        purchaseError = nil
        do {
            try await AppStore.sync()
            await loadPurchaseState()
            if !isPurchased {
                purchaseError = "No previous Beam Unlimited purchase found for this Apple ID."
            }
            logger.info("Restore complete, purchased: \(self.isPurchased)")
        } catch {
            purchaseError = error.localizedDescription
            logger.error("Restore failed: \(error)")
        }
        isPurchasing = false
    }

    // MARK: - Transaction Handling

    private func handleTransactionResult(_ result: VerificationResult<Transaction>) async {
        switch result {
        case .unverified:
            logger.warning("Unverified transaction received")

        case .verified(let transaction):
            guard configuredProductIDs.contains(transaction.productID) else {
                await transaction.finish()
                return
            }

            if transaction.revocationDate == nil {
                await MainActor.run {
                    isPurchased = true
                    activeProductID = transaction.productID
                    purchaseError = nil
                }
                Analytics.iapCompleted()
                // Instantly disable free-tier countdown if user buys mid-session.
                SessionManager.shared.stopSession()
                logger.info("Beam Unlimited unlocked!")
            } else {
                await loadPurchaseState()
            }

            await transaction.finish()
        }
    }

    private func loadPurchaseState() async {
        var purchased = false
        var matchedProductID: String? = nil

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               configuredProductIDs.contains(transaction.productID),
               transaction.revocationDate == nil {
                purchased = true
                matchedProductID = transaction.productID
                break
            }
        }

        let purchasedSnapshot = purchased
        let matchedProductIDSnapshot = matchedProductID

        await MainActor.run {
            isPurchased = purchasedSnapshot
            activeProductID = matchedProductIDSnapshot
            if purchasedSnapshot {
                purchaseError = nil
            }
        }

        if purchasedSnapshot {
            // Keep free-tier state inert if a purchase is active.
            SessionManager.shared.stopSession()
        }
    }

    private var configuredProductIDs: [String] {
        let fromInfoPlist = (Bundle.main.object(forInfoDictionaryKey: kInfoPlistProductIDsKey) as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []

        let source = fromInfoPlist.isEmpty ? kFallbackProductIDs : fromInfoPlist

        var seen = Set<String>()
        var deduped: [String] = []
        for id in source where seen.insert(id).inserted {
            deduped.append(id)
        }
        return deduped
    }
}
