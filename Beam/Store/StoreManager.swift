// StoreManager.swift
// StoreKit 2 IAP for the one-time Beam Unlimited unlock.

import StoreKit
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "StoreManager")

/// Every product id that grants the unlimited entitlement, historic ones included. Purely an
/// ownership question: if a receipt names any of these, the user is unlocked forever.
private let kInfoPlistProductIDsKey = "BeamIAPProductIDs"

/// The discounted launch-price tier, and the regular-price tier it becomes (BEAM-28). Separate
/// products because Apple offers no promotional pricing for non-consumables, so the only honest
/// way to show "X now, Y later" is to have both actually exist in App Store Connect.
private let kInfoPlistPromoProductIDsKey = "BeamIAPPromoProductIDs"
private let kInfoPlistStandardProductIDsKey = "BeamIAPStandardProductIDs"

private let kFallbackProductIDs = [
    "com.beamapp.ios.unlimited",
    "com.beam.ios.unlimited"
]
private let kFallbackStandardProductIDs = [
    "com.beam.ios.unlimited.standard"
]

final class StoreManager: ObservableObject {

    static let shared = StoreManager()

    // MARK: - State

    @Published private(set) var isPurchased: Bool = false

    /// The product a tap on the buy button actually purchases. Always one of the two below.
    @Published private(set) var product: Product? = nil

    /// The discounted launch-price product.
    @Published private(set) var promoProduct: Product? = nil

    /// The regular-price product the promo counts down to.
    ///
    /// Expect this to be `nil` until it is created and approved in App Store Connect, and on
    /// any device that cannot reach the store. Every promo surface treats `nil` as "we cannot
    /// prove the price goes up, so do not claim it does" and falls back to the plain paywall.
    @Published private(set) var standardProduct: Product? = nil

    @Published private(set) var activeProductID: String? = nil
    @Published private(set) var isPurchasing: Bool = false
    @Published private(set) var purchaseError: String? = nil

    private var transactionListener: Task<Void, Never>?

    // MARK: - Init

    private init() {
        #if DEBUG
        // Screenshot/dev only: set before anything reads entitlement, so discovery at launch
        // already sees the device as entitled. See loadPurchaseState.
        if UserDefaults.standard.bool(forKey: "beam.debug.forceUnlimited") {
            isPurchased = true
        }
        #endif

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
        let promoIDs = configuredPromoProductIDs
        let standardIDs = configuredStandardProductIDs
        let requested = dedupe(promoIDs + standardIDs)

        guard !requested.isEmpty else {
            await MainActor.run {
                promoProduct = nil
                standardProduct = nil
                product = nil
                activeProductID = nil
                purchaseError = "No in-app product IDs are configured."
            }
            return
        }

        do {
            // `Product.products(for:)` silently omits ids the store does not know, rather than
            // failing the whole request. That is what makes shipping the regular-price tier
            // ahead of its App Store Connect record safe: it simply comes back missing.
            let products = try await Product.products(for: requested)
            let promo = firstAvailable(in: promoIDs, from: products)
            let standard = firstAvailable(in: standardIDs, from: products)

            await MainActor.run {
                promoProduct = promo
                standardProduct = standard
                recomputeOfferedProduct()
                purchaseError = product == nil ? "Beam Unlimited is not available yet." : nil
            }

            logger.info("Loaded \(products.count) product(s), standard tier available: \(standard != nil)")
        } catch {
            await MainActor.run {
                promoProduct = nil
                standardProduct = nil
                product = nil
                activeProductID = nil
                purchaseError = "Couldn't load pricing. Please try again."
            }
            logger.error("Failed to load products: \(error.localizedDescription)")
        }
    }

    /// Picks which tier is on sale right now.
    ///
    /// Call this after loading products, when the remote promo config changes, and when a
    /// visible countdown reaches zero, so the button never keeps offering a price the paywall
    /// has just finished saying has expired.
    ///
    /// Both fallbacks point at whichever tier did load. If the regular-price product is missing
    /// the app keeps selling the launch price, which under-charges at worst.
    @MainActor
    func recomputeOfferedProduct() {
        let offerPromo = PromoConfig.offersPromoPrice
        let selected = offerPromo
            ? (promoProduct ?? standardProduct)
            : (standardProduct ?? promoProduct)

        guard selected?.id != product?.id else { return }
        product = selected
        activeProductID = isPurchased ? activeProductID : selected?.id
    }

    private func firstAvailable(in ids: [String], from products: [Product]) -> Product? {
        ids.compactMap { id in products.first(where: { $0.id == id }) }.first
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

        #if DEBUG
        // Screenshot/dev only: `-beam.debug.forceUnlimited YES` as a launch argument presents
        // the app as entitled without a StoreKit purchase, so paid-only UI (away-from-home
        // streaming) can be captured in the Simulator. Compiled out of Release entirely.
        if UserDefaults.standard.bool(forKey: "beam.debug.forceUnlimited") {
            await MainActor.run {
                isPurchased = true
                purchaseError = nil
            }
            SessionManager.shared.stopSession()
            return
        }
        #endif

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               configuredProductIDs.contains(transaction.productID),
               transaction.revocationDate == nil {
                purchased = true
                matchedProductID = transaction.productID
                break
            }
        }

        // Reconcile the offline latch against what StoreKit can actually prove.
        //
        // An empty currentEntitlements is ambiguous: it means EITHER "never purchased" OR
        // "cache not populated yet / no network". Treating that as unentitled would lock out
        // paying customers offline, so it is not sufficient evidence to revoke.
        //
        // Transaction.all is the disambiguator. A refunded or revoked purchase still appears
        // there, carrying a revocationDate, so it is positive evidence in a way that absence
        // never is. Only that clears the latch.
        var revoked = false
        for await result in Transaction.all {
            if case .verified(let transaction) = result,
               configuredProductIDs.contains(transaction.productID) {
                if transaction.revocationDate != nil {
                    revoked = true
                } else {
                    // A live transaction outranks any older revoked one (e.g. refunded once,
                    // repurchased later), so stop looking.
                    revoked = false
                    break
                }
            }
        }

        if purchased {
            KeyStore.shared.setPurchaseUnlocked()
        } else if revoked {
            KeyStore.shared.clearPurchaseUnlocked()
        }

        // Fall back to the cached entitlement only when StoreKit could not confirm one and
        // has not proven a revocation.
        if !purchased && !revoked && KeyStore.shared.isPurchaseUnlocked {
            purchased = true
            logger.info("Using cached offline entitlement (StoreKit unavailable)")
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

    /// Every id that counts as owning Beam Unlimited. Union of the explicit entitlement list and
    /// both sale tiers, so a tier can never be sellable without also being honoured.
    private var configuredProductIDs: [String] {
        dedupe(infoPlistIDs(kInfoPlistProductIDsKey, fallback: kFallbackProductIDs)
               + configuredPromoProductIDs
               + configuredStandardProductIDs)
    }

    /// Ordered by preference: the first one the store actually knows is the one offered. That
    /// ordering is what carries the historic bundle-id migration.
    private var configuredPromoProductIDs: [String] {
        dedupe(infoPlistIDs(kInfoPlistPromoProductIDsKey, fallback: kFallbackProductIDs))
    }

    private var configuredStandardProductIDs: [String] {
        dedupe(infoPlistIDs(kInfoPlistStandardProductIDsKey, fallback: kFallbackStandardProductIDs))
    }

    private func infoPlistIDs(_ key: String, fallback: [String]) -> [String] {
        let fromInfoPlist = (Bundle.main.object(forInfoDictionaryKey: key) as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        return fromInfoPlist.isEmpty ? fallback : fromInfoPlist
    }

    private func dedupe(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var deduped: [String] = []
        for id in ids where seen.insert(id).inserted {
            deduped.append(id)
        }
        return deduped
    }
}
