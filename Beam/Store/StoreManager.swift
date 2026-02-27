// StoreManager.swift
// StoreKit 2 IAP for the one-time Beam Unlimited unlock.

import StoreKit
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "StoreManager")

private let kProductID = "com.beam.ios.unlimited"

@Observable
final class StoreManager {

    static let shared = StoreManager()

    // MARK: - State

    private(set) var isPurchased: Bool = false
    private(set) var product: Product? = nil
    private(set) var isPurchasing: Bool = false
    private(set) var purchaseError: String? = nil

    private var transactionListener: Task<Void, Never>?

    // MARK: - Init

    private init() {
        // Restore purchase state
        Task { await loadPurchaseState() }

        // Listen for transaction updates (e.g., from another device)
        transactionListener = Task.detached(priority: .utility) {
            for await result in Transaction.updates {
                await self.handleTransactionResult(result)
            }
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    // MARK: - Load Products

    func loadProduct() async {
        do {
            let products = try await Product.products(for: [kProductID])
            product = products.first
            logger.info("Loaded \(products.count) product(s)")
        } catch {
            logger.error("Failed to load products: \(error)")
        }
    }

    // MARK: - Purchase

    @MainActor
    func purchase() async {
        guard let product else {
            purchaseError = "Product not available. Check your internet connection."
            return
        }

        isPurchasing = true
        purchaseError = nil

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handleTransactionResult(verification)
            case .userCancelled:
                break
            case .pending:
                // Transaction is pending (e.g., Ask to Buy)
                logger.info("Purchase pending")
            @unknown default:
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
        do {
            try await AppStore.sync()
            await loadPurchaseState()
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
            if transaction.productID == kProductID && transaction.revocationDate == nil {
                await MainActor.run { isPurchased = true }
                logger.info("Beam Unlimited unlocked!")
            }
            await transaction.finish()
        }
    }

    private func loadPurchaseState() async {
        #if DEBUG
        // Always treat as purchased in debug builds so the paywall doesn't block testing
        await MainActor.run { isPurchased = true }
        return
        #endif
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == kProductID,
               transaction.revocationDate == nil {
                await MainActor.run { isPurchased = true }
                return
            }
        }
    }
}
