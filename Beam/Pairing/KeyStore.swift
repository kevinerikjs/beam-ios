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
