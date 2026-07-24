// KeyStore.swift
// Keychain-based persistent storage of paired Mac credentials.
// Keychain storage survives app reinstall - intentional for anti-abuse on free tier.

import Foundation
import Security
import OSLog

private let logger = Logger(subsystem: "com.beam.ios", category: "KeyStore")

final class KeyStore {

    static let shared = KeyStore()
    private init() {}

    private let service = "com.beam.ios"
    private let pairedMacKey = "paired_mac"
    private let deviceIDKey = "device_id"

    // MARK: - Paired Mac

    func loadPairedMac() -> PairedMac? {
        guard let data = load(key: pairedMacKey) else { return nil }
        return try? JSONDecoder().decode(PairedMac.self, from: data)
    }

    func savePairedMac(_ mac: PairedMac) {
        guard let data = try? JSONEncoder().encode(mac) else { return }
        save(key: pairedMacKey, data: data)
    }

    func clearPairedMac() {
        delete(key: pairedMacKey)
    }

    // MARK: - Stable Device ID
    // Used for pairing identification. Survives reinstall (stored in Keychain).

    var stableDeviceID: String {
        if let existing = load(key: deviceIDKey), let str = String(data: existing, encoding: .utf8) {
            return str
        }
        let newID = UUID().uuidString
        if let data = newID.data(using: .utf8) {
            save(key: deviceIDKey, data: data)
        }
        return newID
    }

    // MARK: - Feature Unlock Latch (BEAM-18)
    // A remotely-gated feature that has been observed enabled once is unlocked forever on
    // this device. Stored in the Keychain (not UserDefaults) so it survives reinstall, and
    // so a user who has the feature can never lose it by reinstalling while off-network.
    //
    // This is deliberately ONE-WAY: there is no un-latch. Beam has to work on LANs with no
    // internet at all, so "we couldn't reach the flag server" must never disable a feature
    // the user already has. Pulling a feature requires shipping a new build.

    private func latchKey(_ feature: String) -> String { "feature_latch_" + feature }

    func isFeatureUnlocked(_ feature: String) -> Bool {
        guard let data = load(key: latchKey(feature)),
              let value = String(data: data, encoding: .utf8) else { return false }
        return value == "1"
    }

    /// Permanently unlocks `feature` on this device. Idempotent; never reversible.
    func unlockFeature(_ feature: String) {
        guard let data = "1".data(using: .utf8) else { return }
        save(key: latchKey(feature), data: data)
        logger.info("Feature latched on: \(feature, privacy: .public)")
    }

    // Whether the one-time "here's what you just got" changelog has been shown for a feature.
    // Also Keychain-backed, for the same reason as the latch: the notice must show exactly
    // once ever, so it cannot live in UserDefaults where a reinstall would resurrect it.

    private func noticeKey(_ feature: String) -> String { "feature_notice_" + feature }

    func hasShownUnlockNotice(_ feature: String) -> Bool {
        guard let data = load(key: noticeKey(feature)),
              let value = String(data: data, encoding: .utf8) else { return false }
        return value == "1"
    }

    func markUnlockNoticeShown(_ feature: String) {
        guard let data = "1".data(using: .utf8) else { return }
        save(key: noticeKey(feature), data: data)
    }

    // MARK: - Purchase Latch (BEAM-25)
    //
    // StoreKit 2 serves Transaction.currentEntitlements from an on-device cache, so it
    // normally works offline. But it is empty on a fresh install until StoreKit can reach
    // Apple, and it populates asynchronously at launch. In both windows a paying customer
    // looks unentitled, which would lock them out of a feature they bought.
    //
    // So a verified entitlement is mirrored here, in the Keychain, and trusted while offline.
    // This is written ONLY from a StoreKit-verified transaction, never from user input.
    //
    // It is not permanent: see clearPurchaseUnlocked, called when StoreKit gives positive
    // evidence of a revocation. Refunds are honoured the next time the device is online.

    private let purchaseLatchKey = "purchase_unlocked"

    var isPurchaseUnlocked: Bool {
        guard let data = load(key: purchaseLatchKey),
              let value = String(data: data, encoding: .utf8) else { return false }
        return value == "1"
    }

    func setPurchaseUnlocked() {
        guard !isPurchaseUnlocked, let data = "1".data(using: .utf8) else { return }
        save(key: purchaseLatchKey, data: data)
        logger.info("Purchase entitlement cached for offline use")
    }

    func clearPurchaseUnlocked() {
        guard isPurchaseUnlocked else { return }
        delete(key: purchaseLatchKey)
        logger.info("Purchase entitlement revoked, offline cache cleared")
    }

    // MARK: - Keychain Primitives

    private func save(key: String, data: Data) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private func load(key: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
